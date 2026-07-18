import Foundation
import Testing
@testable import DeltaApp

@Suite struct ServiceEventBufferTests {
    @Test func repeatedStateKeepsOnlyLatestValue() async {
        let buffer = ServiceEventBuffer(incomingCapacity: 1, stateCapacity: 2)
        buffer.offer(accountId: 7, event: .configureProgress(permille: 100, comment: nil))
        buffer.offer(accountId: 7, event: .configureProgress(permille: 900, comment: "later"))

        let item = await buffer.next()
        #expect(item?.0 == 7)
        #expect(item?.1 == .configureProgress(permille: 900, comment: "later"))
        #expect(buffer.queuedCount == 0)
        buffer.close()
    }

    @Test func stateOverflowRecoversWithoutEvictingIncoming() async {
        let buffer = ServiceEventBuffer(incomingCapacity: 1, stateCapacity: 1)
        buffer.offer(accountId: 7, event: .chatChanged(chatId: 1))
        buffer.offer(accountId: 7, event: .chatChanged(chatId: 2))
        buffer.offer(accountId: 7, event: .incomingMessage(chatId: 3, msgId: 30))

        let incoming = await buffer.next()
        let recovery = await buffer.next()
        #expect(incoming?.1 == .incomingMessage(chatId: 3, msgId: 30))
        #expect(recovery?.1 == .fullRefreshRequired)
        buffer.close()
    }

    @Test func syntheticStateBurstStaysBoundedAndConvergesToRecovery() async {
        let buffer = ServiceEventBuffer(incomingCapacity: 2, stateCapacity: 2)
        for chatId in 1 ... 1_000 {
            buffer.offer(accountId: 7, event: .chatChanged(chatId: UInt32(chatId)))
            #expect(buffer.queuedCount <= 3)
        }

        var sawRecovery = false
        while buffer.queuedCount > 0 {
            if await buffer.next()?.1 == .fullRefreshRequired {
                sawRecovery = true
            }
        }
        #expect(sawRecovery)
        buffer.close()
    }

    @Test func fullIncomingQueueBackpressuresInsteadOfDropping() async {
        let buffer = ServiceEventBuffer(incomingCapacity: 1, stateCapacity: 1)
        buffer.offer(accountId: 7, event: .incomingMessage(chatId: 3, msgId: 30))
        Thread.detachNewThread {
            buffer.offer(accountId: 7, event: .incomingMessage(chatId: 3, msgId: 31))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while buffer.waitingIncomingProducerCount == 0 {
            guard ContinuousClock.now < deadline else {
                Issue.record("second incoming producer did not backpressure")
                buffer.close()
                return
            }
            await Task.yield()
        }

        let first = await buffer.next()
        #expect(first?.1 == .incomingMessage(chatId: 3, msgId: 30))
        let second = await buffer.next()
        #expect(second?.1 == .incomingMessage(chatId: 3, msgId: 31))
        buffer.close()
    }

    @Test func closeReleasesBlockedIncomingProducer() async {
        let buffer = ServiceEventBuffer(incomingCapacity: 1, stateCapacity: 1)
        buffer.offer(accountId: 7, event: .incomingMessage(chatId: 3, msgId: 30))
        Thread.detachNewThread {
            buffer.offer(accountId: 7, event: .incomingMessage(chatId: 3, msgId: 31))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while buffer.waitingIncomingProducerCount == 0,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(buffer.waitingIncomingProducerCount == 1)

        buffer.close()
        while buffer.waitingIncomingProducerCount > 0,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(buffer.waitingIncomingProducerCount == 0)
        #expect(await buffer.next() == nil)
    }
}
