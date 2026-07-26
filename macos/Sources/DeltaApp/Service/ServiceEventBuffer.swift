import Foundation

/// Bounded bridge from synchronous FFI callbacks to the app's async consumer.
/// Incoming messages apply backpressure and stay FIFO; reconstructible state
/// events coalesce and collapse to an explicit full refresh on overflow.
final class ServiceEventBuffer: @unchecked Sendable {
    typealias Item = (UInt32, ServiceEvent)

    private enum StateKey: Hashable {
        case accounts
        case chatList(UInt32)
        case chat(UInt32, UInt32)
        case configure(UInt32)
        case imex(UInt32)
        case connectivity(UInt32)
        case transcription(UInt32, UInt32)
    }

    private let condition = NSCondition()
    private let incomingCapacity: Int
    private let stateCapacity: Int
    private var incoming: [Item] = []
    private var stateValues: [StateKey: Item] = [:]
    private var stateOrder: [StateKey] = []
    private var recoveryPending = false
    private var consecutiveIncoming = 0
    private var waiter: CheckedContinuation<Item?, Never>?
    private var closed = false
    private var waitingIncomingProducers = 0

    init(incomingCapacity: Int = 128, stateCapacity: Int = 64) {
        precondition(incomingCapacity > 0 && stateCapacity > 0)
        self.incomingCapacity = incomingCapacity
        self.stateCapacity = stateCapacity
    }

    var queuedCount: Int {
        condition.withLock {
            incoming.count + stateOrder.count + (recoveryPending ? 1 : 0)
        }
    }

    var waitingIncomingProducerCount: Int {
        condition.withLock { waitingIncomingProducers }
    }

    func stream() -> AsyncStream<Item> {
        AsyncStream(
            unfolding: { [self] in await next() },
            onCancel: { [self] in close() })
    }

    func offer(accountId: UInt32, event: ServiceEvent) {
        let item = (accountId, event)
        var directWaiter: CheckedContinuation<Item?, Never>?

        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }

        if case .incomingMessage = event {
            while incoming.count >= incomingCapacity, waiter == nil, !closed {
                waitingIncomingProducers += 1
                condition.wait()
                waitingIncomingProducers -= 1
            }
            guard !closed else {
                condition.unlock()
                return
            }
            if let waiter {
                directWaiter = waiter
                self.waiter = nil
            } else {
                incoming.append(item)
            }
        } else if let waiter {
            directWaiter = waiter
            self.waiter = nil
        } else {
            offerStateLocked(item)
        }
        condition.unlock()
        directWaiter?.resume(returning: item)
    }

    func next() async -> Item? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediate: Item?
                var shouldFinish = false

                condition.lock()
                if closed {
                    shouldFinish = true
                } else if let item = popNextLocked() {
                    immediate = item
                } else {
                    precondition(waiter == nil, "ServiceEventBuffer supports one consumer")
                    waiter = continuation
                }
                condition.unlock()

                if shouldFinish {
                    continuation.resume(returning: nil)
                } else if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            close()
        }
    }

    func close() {
        var suspendedConsumer: CheckedContinuation<Item?, Never>?
        condition.lock()
        if !closed {
            closed = true
            incoming.removeAll()
            stateValues.removeAll()
            stateOrder.removeAll()
            recoveryPending = false
            suspendedConsumer = waiter
            waiter = nil
            condition.broadcast()
        }
        condition.unlock()
        suspendedConsumer?.resume(returning: nil)
    }

    private func offerStateLocked(_ item: Item) {
        let key = stateKey(accountId: item.0, event: item.1)
        if case .chatList(let accountId) = key {
            let superseded = stateOrder.filter {
                if case .chat(let existingAccountId, _) = $0 {
                    return existingAccountId == accountId
                }
                return false
            }
            for key in superseded {
                stateValues.removeValue(forKey: key)
                stateOrder.removeAll { $0 == key }
            }
        } else if case .chat(let accountId, _) = key,
                  stateValues[.chatList(accountId)] != nil {
            return
        }

        if stateValues[key] != nil {
            stateValues[key] = item
            return
        }
        guard stateOrder.count < stateCapacity else {
            stateValues.removeAll()
            stateOrder.removeAll()
            recoveryPending = true
            return
        }
        stateValues[key] = item
        stateOrder.append(key)
    }

    private func popNextLocked() -> Item? {
        let stateAvailable = recoveryPending || !stateOrder.isEmpty
        if !incoming.isEmpty, consecutiveIncoming < 8 || !stateAvailable {
            consecutiveIncoming += 1
            let item = incoming.removeFirst()
            condition.broadcast()
            return item
        }
        consecutiveIncoming = 0
        if recoveryPending {
            recoveryPending = false
            return (0, .fullRefreshRequired)
        }
        guard !stateOrder.isEmpty else { return nil }
        let key = stateOrder.removeFirst()
        return stateValues.removeValue(forKey: key)
    }

    private func stateKey(accountId: UInt32, event: ServiceEvent) -> StateKey {
        switch event {
        case .accountsChanged, .fullRefreshRequired: .accounts
        case .chatlistChanged: .chatList(accountId)
        case .chatChanged(let chatId): .chat(accountId, chatId)
        case .configureProgress: .configure(accountId)
        case .imexProgress: .imex(accountId)
        case .connectivityChanged: .connectivity(accountId)
        // Progress ticks coalesce latest-wins per message; terminal states
        // (done/failed) travel on the call's return value, not events.
        case .transcriptionProgress(let msgId, _, _): .transcription(accountId, msgId)
        case .incomingMessage:
            preconditionFailure("incoming messages use the lossless queue")
        }
    }
}
