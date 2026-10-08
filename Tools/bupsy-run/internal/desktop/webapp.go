package desktop

import (
	"bytes"
	_ "embed"
	"image"
	"image/color"
	"image/png"
	"sync"
)

// webApp is the page, the same one the Mac serves to other devices.
//
// A copy of the string in Apps/BupsyMac/Sources/RemoteWebApp.swift, kept identical by
// TestWebAppMatchesTheMac. It is one self-contained file that loads nothing from anywhere else,
// which is what lets the desktop app embed it as is.
//
//go:embed webapp.html
var webApp string

var (
	iconOnce sync.Once
	iconPNG  []byte
)

// icon is the page's home-screen icon: Bupsy's pink, with a face. Drawn rather than shipped, so
// the program stays one file; the Mac renders its app icon here instead.
func icon() []byte {
	iconOnce.Do(func() {
		const size = 512
		img := image.NewNRGBA(image.Rect(0, 0, size, size))
		pink := color.NRGBA{0xd7, 0x6a, 0xbf, 0xff}
		ink := color.NRGBA{0x20, 0x20, 0x20, 0xff}
		inside := func(x, y, cx, cy, r float64) bool { return (x-cx)*(x-cx)+(y-cy)*(y-cy) <= r*r }
		for y := 0; y < size; y++ {
			for x := 0; x < size; x++ {
				fx, fy := float64(x)+0.5, float64(y)+0.5
				switch {
				case inside(fx, fy, 196, 236, 30), inside(fx, fy, 316, 236, 30):
					img.SetNRGBA(x, y, ink)
				case inside(fx, fy, 256, 270, 226):
					img.SetNRGBA(x, y, pink)
				}
			}
		}
		var buf bytes.Buffer
		_ = png.Encode(&buf, img)
		iconPNG = buf.Bytes()
	})
	return iconPNG
}
