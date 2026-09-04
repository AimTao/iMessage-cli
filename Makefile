.PHONY: build install clean doctor chats

build:
	swift build -c release --build-path build

install: build
	cp build/release/imsg ./imsg
	@echo ""
	@echo "已安装: ./imsg"
	@echo "用法:   ./imsg doctor"

clean:
	rm -rf build imsg

doctor: install
	./imsg doctor

chats: install
	./imsg chats
