// Mayhem target `decode` — the natural fuzz surface for rodio: an untrusted audio file's raw
// bytes fed straight into the public decoder entry point `rodio::Decoder::new`, which
// auto-probes the container/codec (WAV, FLAC, MP3, MP4/AAC, Ogg/Vorbis — the crate's default
// feature set, all backed by symphonia) and then decodes every sample. Playback/recording
// (the cpal side) needs a real audio device and is deliberately NOT fuzzed here; decoding
// untrusted bytes is where a real attacker-controlled input lands.
//
// No filesystem access: the harness takes bytes ONLY from the fuzzer via an in-memory
// `Cursor`, per SPEC §6.2 item 13 / the net-new brief §3.
#![no_main]

use libfuzzer_sys::fuzz_target;
use rodio::{Decoder, Source};
use std::io::Cursor;

fuzz_target!(|data: &[u8]| {
    // rodio's symphonia backend boxes the reader as `Box<dyn MediaSource + 'static>`, so an
    // owned buffer is required here — a `Cursor<&[u8]>` borrowing the fuzzer's (non-'static)
    // input slice fails to compile (E0521: "argument requires that `'1` must outlive
    // `'static`"). The copy is cheap relative to decoding and keeps the harness fully in-memory
    // (no file I/O — see the header comment).
    let cursor = Cursor::new(data.to_vec());
    let decoder = match Decoder::new(cursor) {
        Ok(d) => d,
        Err(_) => return,
    };

    // Touch the metadata surface too (cheap, and it exercises symphonia's timing math on
    // whatever container was sniffed).
    let _ = decoder.total_duration();
    let _ = decoder.channels();
    let _ = decoder.sample_rate();

    // Actually decode samples — this is where most real decoder bugs (OOB reads on malformed
    // Huffman/ADPCM/AAC tables, integer overflow in sample-count math, etc.) live, not in the
    // container sniff. Bound the iteration count: some malformed streams could otherwise decode
    // to an enormous (but finite) number of samples and burn the whole fuzzing budget on one
    // input, and this also guards a mistake in this bound belief being wrong from turning into a
    // full stall (this is a normal in-process libFuzzer target, so no external watchdog needed —
    // we just cap the loop instead of relying on a signal-based one).
    let mut n: u64 = 0;
    for sample in decoder {
        std::hint::black_box(sample);
        n += 1;
        if n >= 200_000 {
            break;
        }
    }
});
