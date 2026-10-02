PKG := Packages/BupsyKit

.PHONY: build test spike clean fmt

build:
	swift build --package-path $(PKG)

test:
	swift test --package-path $(PKG)

# M0 spike 3: resolve the engine binary, stream a real run, normalise it.
# Writes a raw capture to docs/samples/ (gitignored — sanitise before using as a fixture).
spike:
	swift run --package-path $(PKG) spike-stream "Run ls in this directory, then say how many entries there are."

clean:
	rm -rf $(PKG)/.build

fmt:
	swift format --in-place --recursive $(PKG)/Sources $(PKG)/Tests

# Generate the Xcode project and build the Mac app.
# The project file is generated, never committed — project.yml is the source of truth.
app:
	xcodegen generate
	xcodebuild -project Bupsy.xcodeproj -scheme BupsyMac -configuration Debug build

run: app
	open "$$(find ~/Library/Developer/Xcode/DerivedData/Bupsy-*/Build/Products/Debug -maxdepth 1 -name 'Bupsy.app' | head -1)"
