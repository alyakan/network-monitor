APP = NetworkMonitor
BUILD = build/$(APP).app

.PHONY: run app clean

run:
	swift run -c release $(APP)

app:
	swift build -c release
	rm -rf $(BUILD)
	mkdir -p $(BUILD)/Contents/MacOS
	cp .build/release/$(APP) $(BUILD)/Contents/MacOS/
	cp Support/Info.plist $(BUILD)/Contents/
	@echo "Built $(BUILD)"

clean:
	rm -rf .build build
