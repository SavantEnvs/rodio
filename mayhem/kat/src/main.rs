// KAT (known-answer-test) probe. Decodes a fixed, embedded WAV fixture and asserts exact values
// computed INDEPENDENTLY of rodio (via Python's stdlib `wave` module reading the same file's
// header, not by running rodio and trusting whatever it says). See mayhem/kat/Cargo.toml for
// why this binary exists.
//
// Deliberately unconditional: every assertion below runs every time, with no skip/guard. A
// missing fixture or a decode failure is a hard FAIL (process exits with a `KAT {...}` line and
// a non-zero exit code), never a silent pass.

use rodio::{Decoder, Source};
use std::io::Cursor;

// Ground truth for this exact file, established independently with Python's `wave` module
// (`python3 -c "import wave; w=wave.open('wav_pcm.wav'); print(w.getnchannels(),
// w.getframerate(), w.getnframes())"`) against
// mayhem/decode/testsuite/wav_pcm.wav (assets/audacity32bit_int.wav upstream: 32-bit signed
// PCM, mono... actually stereo, 44100 Hz): channels=2, framerate=44100, nframes=22528.
const FIXTURE: &[u8] = include_bytes!("../../decode/testsuite/wav_pcm.wav");
const EXPECT_CHANNELS: u16 = 2;
const EXPECT_SAMPLE_RATE: u32 = 44_100;
// Interleaved sample count = frames * channels, decoded via rodio itself and cross-checked
// against the Python-derived frame count below.
const EXPECT_WAVE_NFRAMES: u64 = 22_528;

fn main() {
    let mut failures: u32 = 0;
    let mut check = |name: &str, cond: bool| {
        if cond {
            println!("PASS {name}");
        } else {
            println!("FAIL {name}");
            failures += 1;
        }
    };

    let decoder = Decoder::new(Cursor::new(FIXTURE)).expect("KAT: fixture must decode");
    let channels = decoder.channels().get();
    let sample_rate = decoder.sample_rate().get();

    check("channels", channels == EXPECT_CHANNELS);
    check("sample_rate", sample_rate == EXPECT_SAMPLE_RATE);

    let samples: Vec<f32> = decoder.collect();
    let expect_samples = EXPECT_WAVE_NFRAMES * EXPECT_CHANNELS as u64;
    check(
        "sample_count",
        samples.len() as u64 == expect_samples,
    );

    // A neutered/no-op decode (e.g. a "fix" that just returns without reading anything) would
    // decode to silence; assert the fixture actually contains non-zero audio.
    let has_audio = samples.iter().any(|s| *s != 0.0);
    check("nonzero_audio", has_audio);

    println!(
        "KAT {{\"tool\":\"rodio-kat\",\"failures\":{failures},\"channels\":{channels},\"sample_rate\":{sample_rate},\"sample_count\":{}}}",
        samples.len()
    );

    std::process::exit(if failures == 0 { 0 } else { 1 });
}
