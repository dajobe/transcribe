# Generated Audio Format Fixtures

These fixtures are short deterministic tone files used to verify audio
container preflight across the formats the CLI may encounter.

They were generated from a 4-second mono 16 kHz WAV source made from two sine
tones:

```bash
mkdir -p /tmp/transcribe-format-smoke/fixtures

ffmpeg -hide_banner -y \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -f lavfi -i "sine=frequency=660:duration=2" \
  -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1,volume=0.2" \
  -ar 16000 -ac 1 \
  /tmp/transcribe-format-smoke/fixtures/source.wav
```

The checked-in fixtures were then encoded from that source with:

```bash
ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a pcm_s16le \
  /tmp/transcribe-format-smoke/fixtures/smoke.wav

ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a pcm_s16be \
  /tmp/transcribe-format-smoke/fixtures/smoke.aiff

ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a pcm_s16le \
  /tmp/transcribe-format-smoke/fixtures/smoke.caf

ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a aac -b:a 64k \
  /tmp/transcribe-format-smoke/fixtures/smoke.m4a

ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a aac -b:a 64k \
  /tmp/transcribe-format-smoke/fixtures/smoke.aac

ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a flac \
  /tmp/transcribe-format-smoke/fixtures/smoke.flac

ffmpeg -hide_banner -y -i /tmp/transcribe-format-smoke/fixtures/source.wav \
  -ar 16000 -ac 1 -c:a libmp3lame -b:a 64k \
  /tmp/transcribe-format-smoke/fixtures/smoke.mp3
```

They were copied into this test fixture directory with:

```bash
mkdir -p Tests/transcribeTests/Fixtures/AudioFormats

cp /tmp/transcribe-format-smoke/fixtures/smoke.wav Tests/transcribeTests/Fixtures/AudioFormats/smoke.wav
cp /tmp/transcribe-format-smoke/fixtures/smoke.aiff Tests/transcribeTests/Fixtures/AudioFormats/smoke.aiff
cp /tmp/transcribe-format-smoke/fixtures/smoke.caf Tests/transcribeTests/Fixtures/AudioFormats/smoke.caf
cp /tmp/transcribe-format-smoke/fixtures/smoke.m4a Tests/transcribeTests/Fixtures/AudioFormats/smoke.m4a
cp /tmp/transcribe-format-smoke/fixtures/smoke.aac Tests/transcribeTests/Fixtures/AudioFormats/smoke.aac
cp /tmp/transcribe-format-smoke/fixtures/smoke.flac Tests/transcribeTests/Fixtures/AudioFormats/smoke.flac
cp /tmp/transcribe-format-smoke/fixtures/smoke.mp3 Tests/transcribeTests/Fixtures/AudioFormats/smoke.mp3
```

Current SHA-256 checksums:

```text
baa188756c193be339a1c89ed957bbe8f5a115a7abdada806b916f910bc828ee  smoke.aac
cb8d30a2f22ec263e42c3df00a22b4e91f9e8b7c6a4e574e8d63d4f1a286a493  smoke.aiff
d587b9e0255453e7fed2f607f2cb3c0624b40d4d33ade6937beaa1c9bfb223d3  smoke.caf
a2df6bd20def3dc3ab96f7e8631e2adfba9b94951f7f648bda92d90e8be00ec2  smoke.flac
fd3a580d933745966d52c65683f9d0ff0429e925f89e281e1f2e885780cc3189  smoke.m4a
0c75fc0fb5b901d24106dfcd552f0f21286d24b5b46ae0bf098419d26e18b3ff  smoke.mp3
a360f9b8c3004e67aa3c7938a10099d8b42fddd4984c291a8648bba7cf202328  smoke.wav
```
