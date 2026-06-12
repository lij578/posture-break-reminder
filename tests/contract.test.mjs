import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = readFileSync(new URL("../Sources/main.swift", import.meta.url), "utf8");
const makeDmgScript = readFileSync(new URL("../scripts/make-dmg.sh", import.meta.url), "utf8");
const buildScript = readFileSync(new URL("../scripts/build.sh", import.meta.url), "utf8");
const infoPlist = readFileSync(new URL("../config/Info.plist", import.meta.url), "utf8");

function assertContains(needle) {
  assert.equal(source.includes(needle), true, `expected source to contain: ${needle}`);
}

function assertNotContains(needle) {
  assert.equal(source.includes(needle), false, `expected source not to contain: ${needle}`);
}

test("observation window supports fixed and random modes", () => {
  assertContains("enum ObservationTimeMode");
  assertContains('case fixed = "fixed"');
  assertContains('case random = "random"');
  assertContains("observationTimeModeKey");
  assertContains("fixedObservationWindowMinutesKey");
  assertContains("minimumObservationPhotosKey");
  assertContains("nextObservationWindow()");
  assertContains("sampler.observeFor(\n            seconds: observationWindow");
  assertContains("stopSessionBetweenSamples");
});

test("prompt save and reset do not play confirmation speech", () => {
  assertNotContains('speak("提醒文案已保存")');
  assertNotContains('speak("已恢复默认提醒文案")');
});

test("prompt changes clear custom audio and fall back to live speech", () => {
  assertContains("clearCustomAudioForPromptChange");
  assertContains("preferences.soundMode = .speech");
  assertNotContains("let clearAudioButton = button");
});

test("sound modes exclude custom audio plus speech", () => {
  assertNotContains("audioThenSpeech");
  assertNotContains("自定义音频 + 朗读文案");
});

test("each observation window saves sampled photos in an end-time folder", () => {
  assertContains("sampleImageDatas");
  assertContains("saveObservationImages");
  assertContains("beginObservationImageCapture");
  assertContains(".in-progress");
  assertContains("finalize(endedAt:");
  assertContains('dateFormat = "yyyy-MM-dd_HH-mm-ss"');
  assertContains('String(format: "sample-%02d.jpg"');
  assertContains("imageFolderName");
});

test("sample queue helpers avoid dispatch_sync onto the same serial queue", () => {
  assertContains("DispatchSpecificKey");
  assertContains("sampleQueue.setSpecific");
  assertContains("isOnSampleQueue");
  assertContains("nextSampleDelayLocked");
});

test("completed observation with a present person always triggers a reminder", () => {
  assertNotContains("guard !finalResult.issues.isEmpty else");
  assertContains("showReminder(result: finalResult, reason: reason)");
  assertContains("playReminderSound(text: reminderText)");
});

test("reminder delivery can be speech only, popup only, or both", () => {
  assertContains("enum ReminderDeliveryMode");
  assertContains('case speechAndPopup = "speechAndPopup"');
  assertContains('case speechOnly = "speechOnly"');
  assertContains('case popupOnly = "popupOnly"');
  assertContains("reminderDeliveryModeKey");
  assertContains("usesSound");
  assertContains("usesPopup");
  assertContains("onReminderDeliveryModeChanged");
});

test("reminder trigger can require a visible person or fire by time", () => {
  assertContains("enum ReminderTriggerMode");
  assertContains('case personVisible = "personVisible"');
  assertContains('case timeElapsed = "timeElapsed"');
  assertContains("reminderTriggerModeKey");
  assertContains("triggerModePopup");
  assertContains("onReminderTriggerModeChanged");
  assertContains("preferences.reminderTriggerMode == .personVisible");
  assertContains("let absenceCancelSampleCount = preferences.reminderTriggerMode == .timeElapsed");
});

test("camera warmup black frames are ignored instead of saved as samples", () => {
  assertContains("minimumUsableFrameBrightness");
  assertContains("frameBrightness(from: pixelBuffer)");
  assertContains("guard brightness >= minimumUsableFrameBrightness else");
  assertContains("currentSampleStartedAt");
});

test("observation settings include adjustable minimum photos and apply immediately", () => {
  assertContains("minimumPhotosField");
  assertContains("preferences.minimumObservationPhotos");
  assertContains("restartObservationWithCurrentSettings");
  assertContains("sampler.cancel()");
  assertContains("minimumPhotos: preferences.minimumObservationPhotos");
});

test("main settings use grouped macOS-style sections and remove redundant quit controls", () => {
  assertContains("settingsSection(title:");
  assertContains("settingsRow(label:");
  assertContains("主要操作");
  assertContains("观察采样");
  assertContains("historySection(historyView: historyListView)");
  assertContains("root.alignment = .leading");
  assertContains("addFullWidth(");
  assertContains("contentStack.alignment = .width");
  assertContains("final class FlippedView");
  assertContains("titleLabel.alignment = .left");
  assertContains("titleLabel.leadingAnchor.constraint(equalTo: section.leadingAnchor)");
  assertContains("controlsStack.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor");
  assertContains('formatter.dateFormat = "MM-dd HH:mm:ss"');
  assertNotContains('let quitButton = button(title: "退出应用"');
  assertNotContains('NSMenuItem(title: "退出", action: #selector(quit)');
});

test("active observation shows the next photo time", () => {
  assertContains("nextPhotoAt");
  assertContains("nextPhotoLabel");
  assertContains("nextSampleHandler");
  assertContains("下次拍照");
});

test("prompt template editor remains visible and editable", () => {
  assertContains("promptEditorRow(promptScroll:");
  assertContains("promptScroll.translatesAutoresizingMaskIntoConstraints = false");
  assertContains("promptScroll.trailingAnchor.constraint(equalTo: row.trailingAnchor)");
  assertContains("promptTextView.isEditable = true");
  assertContains("promptTextView.isSelectable = true");
  assertContains("promptTextView.string = preferences.promptTemplate");
  assertNotContains('settingsRow(label: "模板", controls: [promptScroll])');
});

test("history records are anchored to the top-left without large empty margins", () => {
  assertContains("private let historyListView = FlippedView()");
  assertContains("historySection(historyView: historyListView)");
  assertContains("recordView.leadingAnchor.constraint(equalTo: historyListView.leadingAnchor)");
  assertContains("recordView.trailingAnchor.constraint(equalTo: historyListView.trailingAnchor)");
  assertContains("recordView.topAnchor.constraint(equalTo: previousBottomAnchor, constant: topSpacing)");
  assertContains("constraints.append(previousBottomAnchor.constraint(equalTo: historyListView.bottomAnchor))");
  assertContains("historyView.leadingAnchor.constraint(equalTo: section.leadingAnchor)");
  assertContains("historyView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)");
  assertContains("container.widthAnchor.constraint(equalTo: row.widthAnchor)");
  assertNotContains("historyView.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor");
  assertNotContains("historyView.topAnchor.constraint(equalTo: boxContentView.topAnchor");
  assertNotContains("historyStack.addArrangedSubview");
  assertNotContains("historyStack.distribution = .fill");
  assertNotContains("container.widthAnchor.constraint(greaterThanOrEqualToConstant: 680)");
  assertNotContains("let historyDocumentView = FlippedView()");
  assertNotContains("scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)");
});

test("dmg is named in Chinese and uses the same volume name", () => {
  assert.equal(makeDmgScript.includes('DMG="$DIST/不要久坐.dmg"'), true);
  assert.equal(makeDmgScript.includes('-volname "不要久坐"'), true);
});

test("launchpad app bundle and display name are Chinese", () => {
  assert.equal(buildScript.includes('APP_DISPLAY_NAME="不要久坐"'), true);
  assert.equal(buildScript.includes('EXECUTABLE_NAME="PostureBreakReminder"'), true);
  assert.equal(buildScript.includes('APP="$ROOT/build/$APP_DISPLAY_NAME.app"'), true);
  assert.equal(infoPlist.includes("<key>CFBundleDisplayName</key>"), true);
  assert.equal(infoPlist.includes("<string>不要久坐</string>"), true);
});
