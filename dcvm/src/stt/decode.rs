//! Decode an audio file to 16 kHz mono f32 PCM in [-1, 1] — the input format
//! the transcription engine expects.
//!
//! Container/codec support is whatever symphonia is compiled with here:
//! wav/pcm, ogg-vorbis, flac (defaults) plus aac, isomp4 (m4a) and mp3.
//! Opus-in-Ogg is deliberately reported as [`SttError::Unsupported`]; core
//! never classifies bare `.opus` files as Voice/Audio, but `.ogg` blobs can
//! still carry Opus streams from other clients.

use std::fs::File;
use std::path::Path;

use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// Target sample rate for the ASR engine.
pub const TARGET_RATE: u32 = 16_000;

#[derive(Debug, thiserror::Error)]
pub enum SttError {
    #[error("audio file not found: {0}")]
    FileMissing(String),
    #[error("unsupported audio format: {0}")]
    Unsupported(String),
    #[error("failed to decode audio: {0}")]
    Decode(String),
    #[error("transcription failed: {0}")]
    Engine(String),
    #[error("audio is too long to transcribe (limit {0} seconds)")]
    TooLong(u32),
}

/// Refuse absurdly long inputs: decoded f32 PCM for a 30-minute 48 kHz file
/// is already ~330 MB, and Parakeet's full-attention window is 24 minutes.
const MAX_INPUT_SECONDS: u32 = 1_800;

/// Decode `path` and return mono f32 samples at [`TARGET_RATE`].
pub fn decode_to_pcm_16k(path: &Path) -> Result<Vec<f32>, SttError> {
    let (samples, src_rate) = decode_file(path, MAX_INPUT_SECONDS)?;
    resample(&samples, src_rate, TARGET_RATE)
}

fn decode_file(path: &Path, max_seconds: u32) -> Result<(Vec<f32>, u32), SttError> {
    if !path.is_file() {
        return Err(SttError::FileMissing(path.display().to_string()));
    }
    let file =
        File::open(path).map_err(|e| SttError::Decode(format!("cannot open audio file: {e}")))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| SttError::Unsupported(format!("unrecognized container: {e}")))?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| SttError::Unsupported("no audio track".into()))?;
    let track_id = track.id;
    let src_rate = track
        .codec_params
        .sample_rate
        .filter(|r| *r > 0)
        .ok_or_else(|| SttError::Decode("unknown sample rate".into()))?;
    let max_samples = src_rate as u64 * max_seconds as u64;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| SttError::Unsupported(format!("codec: {e}")))?;

    let mut mono = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            // Both mark ordinary end-of-stream for the containers we read.
            Err(SymphoniaError::IoError(e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break
            }
            Err(SymphoniaError::ResetRequired) => break,
            Err(e) => return Err(SttError::Decode(e.to_string())),
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(buf) => {
                let spec = *buf.spec();
                let mut samples = SampleBuffer::<f32>::new(buf.capacity() as u64, spec);
                samples.copy_interleaved_ref(buf);
                mono.extend(downmix_to_mono(samples.samples(), spec.channels.count()));
                if mono.len() as u64 > max_samples {
                    return Err(SttError::TooLong(max_seconds));
                }
            }
            // A corrupt packet is skippable; anything else is fatal.
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(e) => return Err(SttError::Decode(e.to_string())),
        }
    }
    if mono.is_empty() {
        return Err(SttError::Decode("no audio frames decoded".into()));
    }
    Ok((mono, src_rate))
}

/// Average interleaved frames down to one channel.
fn downmix_to_mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks_exact(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

/// Windowed-sinc resample of a mono buffer from `src_rate` to `dst_rate`.
fn resample(input: &[f32], src_rate: u32, dst_rate: u32) -> Result<Vec<f32>, SttError> {
    if src_rate == dst_rate {
        return Ok(input.to_vec());
    }
    if src_rate == 0 {
        return Err(SttError::Decode("invalid sample rate 0".into()));
    }
    let map_err = |e: &dyn std::fmt::Display| SttError::Decode(format!("resample: {e}"));
    let params = SincInterpolationParameters {
        sinc_len: 128,
        f_cutoff: 0.95,
        oversampling_factor: 128,
        interpolation: SincInterpolationType::Linear,
        window: WindowFunction::Blackman2,
    };
    const CHUNK: usize = 1024;
    let mut resampler =
        SincFixedIn::<f32>::new(dst_rate as f64 / src_rate as f64, 1.0, params, CHUNK, 1)
            .map_err(|e| map_err(&e))?;
    let expected = (input.len() as u64 * dst_rate as u64 / src_rate as u64) as usize;
    let mut out = Vec::with_capacity(expected + CHUNK);
    let mut pos = 0;
    while pos < input.len() {
        let need = resampler.input_frames_next();
        let produced = if input.len() - pos >= need {
            let chunk = &input[pos..pos + need];
            pos += need;
            resampler.process(&[chunk], None).map_err(|e| map_err(&e))?
        } else {
            let chunk = &input[pos..];
            pos = input.len();
            resampler
                .process_partial(Some(&[chunk]), None)
                .map_err(|e| map_err(&e))?
        };
        out.extend_from_slice(&produced[0]);
    }
    // Drain the sinc filter's delay line.
    let tail = resampler
        .process_partial::<&[f32]>(None, None)
        .map_err(|e| map_err(&e))?;
    out.extend_from_slice(&tail[0]);
    // The filter delays the signal by output_delay() frames of leading
    // silence; everything past `expected` is zero-padding from the final
    // partial chunk and the flush. Trim each from its own end, or timing
    // shifts by tens of milliseconds and clips speech onsets.
    let delay = resampler.output_delay();
    out.drain(..delay.min(out.len()));
    out.truncate(expected);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;
    use std::io::Write;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    /// Minimal RIFF/WAVE writer: 16-bit PCM, interleaved.
    fn write_wav(path: &Path, samples: &[i16], channels: u16, rate: u32) {
        let data_len = (samples.len() * 2) as u32;
        let byte_rate = rate * channels as u32 * 2;
        let block_align = channels * 2;
        let mut bytes = Vec::with_capacity(44 + data_len as usize);
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
        bytes.extend_from_slice(&channels.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&byte_rate.to_le_bytes());
        bytes.extend_from_slice(&block_align.to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        for s in samples {
            bytes.extend_from_slice(&s.to_le_bytes());
        }
        File::create(path).unwrap().write_all(&bytes).unwrap();
    }

    fn sine_i16(rate: u32, secs: f32, hz: f32, amplitude: f32) -> Vec<i16> {
        let frames = (rate as f32 * secs) as usize;
        (0..frames)
            .map(|i| {
                let v = (TAU * hz * i as f32 / rate as f32).sin() * amplitude;
                (v * i16::MAX as f32) as i16
            })
            .collect()
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
    }

    #[test]
    fn wav_48k_stereo_becomes_16k_mono() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tone.wav");
        let mono = sine_i16(48_000, 1.2, 440.0, 0.5);
        let stereo: Vec<i16> = mono.iter().flat_map(|s| [*s, *s]).collect();
        write_wav(&path, &stereo, 2, 48_000);

        let pcm = decode_to_pcm_16k(&path).unwrap();
        let expected = (1.2 * TARGET_RATE as f32) as usize;
        assert!(
            (pcm.len() as i64 - expected as i64).unsigned_abs() < 200,
            "expected ~{expected} samples, got {}",
            pcm.len()
        );
        assert!(pcm.iter().all(|s| s.abs() <= 1.0), "samples out of range");
        // A 0.5-amplitude sine has RMS ~0.35; resampling must keep energy.
        let r = rms(&pcm);
        assert!((0.2..=0.5).contains(&r), "rms {r} out of expected range");
    }

    #[test]
    fn m4a_fixture_decodes() {
        let pcm = decode_to_pcm_16k(&fixture("voice.m4a")).unwrap();
        // 1.2 s tone; AAC adds priming/padding frames, so bounds are loose.
        assert!(
            (15_000..=25_000).contains(&pcm.len()),
            "unexpected sample count {}",
            pcm.len()
        );
        assert!(rms(&pcm) > 0.05, "decoded audio is silent");
    }

    #[test]
    fn opus_in_ogg_reports_unsupported() {
        let err = decode_to_pcm_16k(&fixture("voice-opus.ogg")).unwrap_err();
        assert!(
            matches!(err, SttError::Unsupported(_)),
            "expected Unsupported, got {err:?}"
        );
    }

    #[test]
    fn missing_file_reports_file_missing() {
        let err = decode_to_pcm_16k(Path::new("/nonexistent/voice.m4a")).unwrap_err();
        assert!(matches!(err, SttError::FileMissing(_)));
    }

    #[test]
    fn garbage_bytes_report_unsupported_container() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("noise.m4a");
        std::fs::write(&path, [0u8; 512]).unwrap();
        let err = decode_to_pcm_16k(&path).unwrap_err();
        assert!(matches!(err, SttError::Unsupported(_)), "got {err:?}");
    }

    #[test]
    fn downmix_averages_channels() {
        let out = downmix_to_mono(&[1.0, 0.0, 0.5, 0.5, -1.0, 1.0], 2);
        assert_eq!(out, vec![0.5, 0.5, 0.0]);
    }

    #[test]
    fn resample_is_identity_at_target_rate() {
        let input = vec![0.1, 0.2, 0.3];
        assert_eq!(resample(&input, 16_000, 16_000).unwrap(), input);
    }

    #[test]
    fn resample_preserves_leading_onset() {
        // 50 ms marker at the very start, then silence. The sinc filter's
        // delay compensation must not eat the onset (a resampler that trims
        // the wrong end passes every length/RMS check but clips first words).
        let rate = 48_000;
        let mut input = vec![0.0f32; rate as usize];
        for (i, s) in input.iter_mut().take(2_400).enumerate() {
            *s = (TAU * 440.0 * i as f32 / rate as f32).sin() * 0.9;
        }
        let out = resample(&input, rate, 16_000).unwrap();
        assert!(
            (out.len() as i64 - 16_000).unsigned_abs() < 100,
            "expected ~16000, got {}",
            out.len()
        );
        let head = rms(&out[..800]);
        assert!(head > 0.3, "onset lost: head rms {head}");
        let tail = rms(&out[8_000..]);
        assert!(tail < 0.02, "tail should be near-silent, rms {tail}");
    }

    #[test]
    fn resample_keeps_timing_aligned() {
        // Impulses at 0.1 s and 0.5 s must land at 0.1 s and 0.5 s in the
        // output. Off-by-a-chunk trim errors shift everything audibly.
        let rate = 48_000;
        let mut input = vec![0.0f32; rate as usize];
        input[4_800] = 1.0;
        input[24_000] = 1.0;
        let out = resample(&input, rate, 16_000).unwrap();
        let peaks: Vec<usize> = {
            let mut idx: Vec<usize> = (0..out.len()).collect();
            idx.sort_by(|a, b| out[*b].abs().total_cmp(&out[*a].abs()));
            let mut top = vec![idx[0]];
            // second peak: first index not adjacent to the strongest
            top.push(*idx.iter().find(|i| i.abs_diff(idx[0]) > 100).unwrap());
            top.sort();
            top
        };
        // ±32 samples = 2 ms: covers rubato's reported-vs-actual delay
        // rounding while still catching chunk-sized (20 ms+) trim errors.
        assert!(
            peaks[0].abs_diff(1_600) <= 32 && peaks[1].abs_diff(8_000) <= 32,
            "impulses at {peaks:?}, expected ~[1600, 8000]"
        );
    }

    #[test]
    fn resample_rejects_zero_source_rate() {
        let err = resample(&[0.1, 0.2], 0, 16_000).unwrap_err();
        assert!(matches!(err, SttError::Decode(_)), "got {err:?}");
    }

    #[test]
    fn overlong_audio_is_rejected() {
        // The 1.2 s fixture against a 1 s cap stands in for the real
        // 30-minute limit without a giant fixture.
        let err = decode_file(&fixture("voice.m4a"), 1).unwrap_err();
        assert!(matches!(err, SttError::TooLong(1)), "got {err:?}");
    }

    #[test]
    fn resample_halves_length_from_32k() {
        let input: Vec<f32> = sine_i16(32_000, 1.0, 440.0, 0.5)
            .iter()
            .map(|s| *s as f32 / i16::MAX as f32)
            .collect();
        let out = resample(&input, 32_000, 16_000).unwrap();
        assert!(
            (out.len() as i64 - 16_000).unsigned_abs() < 100,
            "expected ~16000, got {}",
            out.len()
        );
    }
}
