`sample.mp4` is an original synthetic one-second test fixture, generated locally:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=160x90:rate=24:duration=1' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' \
  -c:v libx264 -pix_fmt yuv420p -preset ultrafast -crf 30 \
  -c:a aac -b:a 64k -shortest -movflags +faststart sample.mp4
```

It contains H.264 video at 160 × 90, 24 fps, and AAC audio. The XCTest integration
test scans and transcodes this media through the actual `HBEngine` bridge and
checks the generated asset's duration, video dimensions, and audio track.
