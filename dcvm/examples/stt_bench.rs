//! Latency probe for the transcription path (issue: stt-performance).
//! `cargo run --example stt_bench -- <model.gguf> <audio-file>`
//! Prints resolved backend, model load time, and per-run inference time /
//! real-time factor (3 runs: first shows warmup, rest steady state).

use std::path::Path;
use std::time::Instant;

use dcvm::stt::{decode_to_pcm_16k, ParakeetEngine, SttEngine};

fn main() {
    let mut args = std::env::args().skip(1);
    let model = args.next().expect("usage: stt_bench <model.gguf> <audio>");
    let audio = args.next().expect("usage: stt_bench <model.gguf> <audio>");

    let t = Instant::now();
    let pcm = decode_to_pcm_16k(Path::new(&audio)).expect("decode");
    let audio_secs = pcm.len() as f32 / 16_000.0;
    println!("decode: {:.2}s for {audio_secs:.1}s of audio", t.elapsed().as_secs_f32());

    let t = Instant::now();
    let engine = ParakeetEngine::load(Path::new(&model)).expect("load");
    println!(
        "load:   {:.2}s  backend: {}",
        t.elapsed().as_secs_f32(),
        engine.backend_name()
    );

    for i in 1..=3 {
        let t = Instant::now();
        let text = engine.transcribe(&pcm).expect("transcribe");
        let dt = t.elapsed().as_secs_f32();
        println!(
            "run {i}:  {:.2}s  rtf {:.3}  text: {:?}",
            dt,
            dt / audio_secs,
            text.chars().take(60).collect::<String>()
        );
    }
}
