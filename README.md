# ZnKeyboard for iOS

Pinyin keyboard for iPhone with AI polish and translate, the same engine as the Android keyboard.
In progress: it has not run on a device yet.

Scope on iOS: pinyin, polish and translate, and translating copied text. No voice input, screenshot
or selection translation.

## Layout

- `Sources/PinyinCore`: the engine, dictionary, learning, AI requests and keyboard logic, in pure Swift.
- `Keyboard`: the keyboard extension.
- `App`: the app that sets it up.
- `tools`: builds `dict.bin` and the prompts from the Android keyboard's files.

## Build

Needs Xcode with the iOS platform, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open ZnKeyboard.xcodeproj
```

## Check the engine

Runs on a Mac. `dict.tsv`, `trade.tsv`, `lm.bin` and `bench.tsv` come from the Android repository;
the two case files come from its `tools/pinyin/bench/run_bench.sh --cases`.

```bash
swift build -c release
.build/release/checks Sources/PinyinCore/Resources/dict.bin Sources/PinyinCore/Resources/lm.bin bench.tsv learn-cases.tsv
.build/release/footprint Sources/PinyinCore/Resources/dict.bin Sources/PinyinCore/Resources/lm.bin cases.tsv
```

Dictionary and prompts, after changing them on Android:

```bash
tools/build_dict.py dict.tsv trade.tsv Sources/PinyinCore/Resources/dict.bin
tools/build_prompts.py assets/prompts Sources/PinyinCore/Prompts.generated.swift
```
