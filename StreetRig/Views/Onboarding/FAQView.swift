//
//  FAQView.swift
//  StreetRig
//
//  THE PAGE FOR THE TWO COMPLAINTS THIS APP ACTUALLY GETS: "there's an echo"
//  and "there's a horrible noise". Reached from Settings → Help & guides, and
//  written for somebody who is holding a guitar and is about to decide the app
//  is broken.
//
//  WHY IT IS NOT MORE GUIDE PAGES. `SetupGuideView` is a linear thing you are
//  shown once, before you have heard a note — it can only carry what everybody
//  needs in the ninety seconds before they play, which is why its copy rule is
//  one idea per page. The echo and the noise are different: you go looking for
//  them, at the moment they happen, with a specific symptom in your ears. That
//  is a lookup, not a walkthrough, so this is a list you can aim at.
//
//  THE POSITION THIS PAGE TAKES, and it is a position rather than an apology:
//  StreetRig is modelling real amplifiers as faithfully as it can manage, and a
//  real amplifier with the gain up is NOT SILENT. It hisses between notes, it
//  hums near a screen, and it will howl if it can hear its own speaker. The app
//  could scrub all of that out — but the same processing that removes a hiss
//  removes the tail of a chord and the give in a pick attack, and what is left
//  is quiet and wrong. So the answer here is the answer a real board uses: a
//  noise gate, set by the player, by ear.
//
//  EVERY NUMBER ON THIS PAGE IS SOMEBODY'S MEASUREMENT OR SOMEBODY'S CONSTANT,
//  the same rule `SetupGuideView` holds itself to. The −56 dBFS line, the 4:1
//  slope, the 1 ms open and 250 ms close are `DSPKernel`'s; the −70…−20 dBFS
//  threshold sweep and the 20…600 ms decay are `ParameterMap`'s; the 42 dB and
//  the 172/25 ms are measurements in `AudioEngineController`. If one of those
//  changes, this file changes with it.
//
//  LANDSCAPE SHAPE: questions left, the answer right, on one row. An accordion
//  was the first cut and it is the wrong shape here — this screen is barely
//  390 pt tall, so expanding an answer pushes every other question off the
//  bottom and the list you were scanning stops existing. Side by side, the
//  question list never moves and the answer gets a proper measure.
//

import SwiftUI
import StreetRigEngine

// MARK: - Data

/// One question and everything the answer needs.
///
/// Held as data for the same reason `SetupGuidePage.all` and `Credits.all` are:
/// the order, the count and the selection are then one array, and adding a
/// question is appending to it rather than editing a view.
struct FAQEntry: Identifiable {
    let id: Int
    /// In the player's words, including the wrong words — somebody hearing a
    /// 172 ms round trip calls it an echo, and a question they cannot recognise
    /// is a question they cannot find.
    let question: String
    /// The one line under the question in the list. It must answer, not tease:
    /// half the time this is all somebody needs and they never tap through.
    let short: String
    let symbol: String
    let paragraphs: [String]
    /// Numbered instructions, when the answer is something to go and do.
    let steps: [String]
    /// The traceable fact, set apart the way the setup guide sets its own apart
    /// — it is the part a sceptical player will want to check.
    let note: String?

    init(id: Int, question: String, short: String, symbol: String,
         paragraphs: [String], steps: [String] = [], note: String? = nil) {
        self.id = id
        self.question = question
        self.short = short
        self.symbol = symbol
        self.paragraphs = paragraphs
        self.steps = steps
        self.note = note
    }
}

enum FAQ {
    /// ORDERED BY WHAT IS IN SOMEBODY'S EARS, not by topic. The two symptoms come
    /// first because they are why the page was opened; the gate follows because
    /// it is the answer to both; the reasoning comes last, for the player who
    /// wants to know why the app did not just handle it.
    static let all: [FAQEntry] = [
        FAQEntry(
            id: 0,
            question: "Why do I hear an echo?",
            short: "Three causes, and only one of them is the app.",
            symbol: "waveform.path.ecg",
            paragraphs: [
                "An electric guitar is never silent in the room — you always hear the "
                + "strings themselves. So anything that brings your playing back a "
                + "fraction of a second later arrives as a second copy, and a second "
                + "copy is an echo. There are exactly three things that do it.",

                "BLUETOOTH, and it is the usual one. You are not hearing an echo so "
                + "much as hearing yourself late: A2DP buffers by protocol design, and "
                + "no amount of DSP touches it. Go wired and it disappears.",

                "A DELAY OR REVERB ON THE BOARD. The starter rig ships with both — a "
                + "VOSS Digital Delay and a VOSS Reverb sit on it from the first "
                + "launch. That is a real echo, made on purpose by a real pedal. Tap "
                + "the pedal on the rig and pull Mix down, or drag it off the board.",

                "THE PHONE HEARING ITSELF. With no interface plugged in, the input is "
                + "the built-in mic and the output is the speaker an inch away from it. "
                + "The amp then amplifies its own output, which rings, then howls. An "
                + "interface or headphones ends it; a noise gate stops it building in "
                + "the gaps."
            ],
            note: "Measured on an iPhone 17e: 172 ms round trip over Bluetooth, 163 of "
                + "it the output port alone. Wired lands near 25 ms. OUTPUT on the "
                + "control panel shows yours, live."
        ),
        FAQEntry(
            id: 1,
            question: "Why is there a horrible noise?",
            short: "Because a real amp does that. Gate it.",
            symbol: "waveform.badge.exclamationmark",
            paragraphs: [
                "Hiss, buzz, a roar that swells while you are not playing and stops "
                + "dead when you mute the strings: that is a guitar amplifier with the "
                + "gain up, and StreetRig is modelling one as faithfully as we can "
                + "manage. A modelled preamp amplifies whatever reaches it, and the "
                + "noise floor reaches it too.",

                "Three things make it worse here than on a real board, and all three "
                + "are real. A guitar arriving through a headphone-jack adapter comes "
                + "in about 42 dB down, so the rig has to invent 42 dB — and it invents "
                + "the hiss along with the guitar. Single coils near a lit phone screen "
                + "hum, the same as they do near anything else. And a high-gain amp "
                + "model has tens of dB of cascaded preamp gain sitting in front of all "
                + "of it.",

                "The fix is the fix every real board uses, and it is the fix this app "
                + "wants you to use: put a NOISE GATE on the rig and set it by ear. It "
                + "shuts the gaps between notes and stays out of the way of the notes."
            ],
            note: "The rig is already doing part of this for you — see \"Isn't there "
                + "a gate already?\" — but the part that is set to your amp, your "
                + "pickups and your room is the pedal, and it is yours to set."
        ),
        FAQEntry(
            id: 2,
            question: "What does the noise gate do?",
            short: "Shuts below a line you set. Opens in a millisecond.",
            symbol: "switch.2",
            paragraphs: [
                "It watches how loud the signal is. Above a line you set, it does "
                + "nothing at all — a gate is not an effect and it is not meant to be "
                + "heard. Below that line, it turns the signal down to nothing, which "
                + "is where the hiss and the hum and the beginnings of feedback live.",

                "THRESHOLD is the line. Set it just above the roar you hear while your "
                + "hands are off the strings, and just below your quietest real note. "
                + "Too low and the noise walks straight under it; too high and the tail "
                + "of every chord gets cut off, which sounds worse than the noise did.",

                "DECAY is how fast it shuts once you stop. Short is tight and "
                + "percussive — the metal setting. Long lets notes ring out and die "
                + "naturally, at the cost of a little noise behind the tail. Opening is "
                + "not adjustable and never should be: it happens in about a "
                + "millisecond, so a pick attack is never late."
            ],
            note: "Threshold sweeps −70 to −20 dBFS across the knob; Decay runs 20 to "
                + "600 ms. It reopens at the threshold and shuts 6 dB below it, so a "
                + "note dying right on the line cannot chatter."
        ),
        FAQEntry(
            id: 3,
            question: "How do I get a noise gate?",
            short: "It's in the gear library, under Noise Gate.",
            symbol: "square.grid.2x2.fill",
            paragraphs: [
                "You do not have one to start with — the starter board is a drive, a "
                + "delay and a reverb, which is a board that sounds good and makes "
                + "noise. The gate is one page away."
            ],
            steps: [
                "Swipe to GEAR LIBRARY and pick the Pedal tab.",
                "Open the Noise Gate card and tap the VOSS Noise Silencer. It is "
                + "yours now, and it appears in the MY GEAR rail.",
                "Press its card in the rail until it lifts, then drag it onto the rig.",
                "Tap it on the rig to zoom in, and set Threshold and Decay by ear."
            ],
            note: "The board holds three pedals and the starter board is already full, "
                + "so something comes off to make room. You never have to place the "
                + "gate in order: the board sorts itself into signal-chain order, and a "
                + "gate lands after the drive, which is where it belongs. Or skip all "
                + "of this: the TONES square on the rig page loads whole rigs, and every "
                + "high-gain one brings a gate already set."
        ),
        FAQEntry(
            id: 4,
            question: "Isn't there a gate already?",
            short: "There is one. It is set low on purpose, and that is why.",
            symbol: "gauge.with.dots.needle.bottom.50percent",
            paragraphs: [
                "Yes. The rig runs a permanent downward expander of its own, below "
                + "everything you can reach: anything under −56 dBFS is pulled down by "
                + "4:1, and that line rises as you raise the amp's gain, because more "
                + "gain means more noise to hold down. It opens in a millisecond and "
                + "closes over a quarter of a second, so it can never modulate a note.",

                "It is deliberately set BELOW anything you would ever play — about "
                + "35 dB under a struck note — because it is not allowed to be wrong. "
                + "It is running on every rig, on every setting, for every player, with "
                + "nobody's hands on it. A safety net that judges is a safety net that "
                + "eventually eats somebody's chord.",

                "That is exactly why it cannot be aggressive enough for a cranked "
                + "high-gain patch, and why the pedal exists. The one you put on the "
                + "board knows what you are playing, and you can set it wherever the "
                + "noise actually is."
            ],
            note: "Base line −56 dBFS, rising to roughly −38 dBFS at full drive. The "
                + "gate pedal's own threshold reaches −20 dBFS, well above anything "
                + "the built-in expander is allowed to touch."
        ),
        FAQEntry(
            id: 5,
            question: "Why not just make it quiet?",
            short: "Because a silent amp is the wrong amp.",
            symbol: "target",
            paragraphs: [
                "We could. Noise reduction that aggressive is not hard, and plenty of "
                + "apps ship it switched on. It is not what StreetRig is trying to be.",

                "The whole point of this app is to model real amplifiers to the best of "
                + "our ability — the way they break up, the way they bloom, the way a "
                + "note dies. The processing that scrubs a hiss out of the gaps is the "
                + "same processing that shortens the tail of a chord, flattens the pick "
                + "attack and makes a cranked amp behave like a clean one. You would "
                + "get silence between the notes and a worse amp during them.",

                "Every real board solves this the same way, and it is not by buying a "
                + "quieter amp. It is a gate, at the player's feet, set by ear for the "
                + "room they are in. Giving you the noise and the tool to shut it is "
                + "the honest version of an amplifier. Turning the amp into something "
                + "that cannot make noise is not."
            ],
            note: "Same reasoning as the Bluetooth page in the audio setup guide: this "
                + "app would rather tell you what is actually happening than hide it "
                + "and be quietly wrong."
        )
    ]
}

// MARK: - View

struct FAQView: View {
    /// Back to the settings list. Settings is a page you came from, so this page
    /// owns a title bar and a way out — the same contract `PreferencesView` has
    /// with the profile page.
    var onClose: (() -> Void)?

    @State private var selection = 0

    private var entries: [FAQEntry] { FAQ.all }
    private var entry: FAQEntry { entries[min(selection, entries.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            thesis
            HStack(alignment: .top, spacing: 0) {
                questionList
                    .frame(width: 292)
                Rectangle()
                    .fill(RigTheme.hairline)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                answer
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Chrome

    private var titleBar: some View {
        HStack(spacing: 10) {
            if let onClose {
                Button(action: onClose) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("Settings")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(RigTheme.amber)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to settings")
            }
            Spacer(minLength: 0)
            Text("COMMON QUESTIONS")
                .font(.system(size: 10, weight: .bold))
                .tracking(2)
                .foregroundStyle(RigTheme.textMuted)
            Spacer(minLength: 0)
            // Balances the back button so the title sits on the centre of the
            // bar — the same trick `PreferencesView.titleBar` plays.
            Color.clear.frame(width: 66, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    /// THE ONE SENTENCE THIS WHOLE PAGE RESTS ON, kept on screen behind every
    /// answer rather than buried in one of them. Each entry below is an
    /// application of it, and an app that states its intent once and then argues
    /// from it reads very differently from one that apologises six times.
    private var thesis: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "amplifier")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RigTheme.trim)
                .padding(.top, 1)
            Text("We model real amplifiers to the best of our ability — so the noise "
                 + "is real, and so is the cure: a noise gate.")
                .font(.system(size: 10.5))
                .foregroundStyle(RigTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    // MARK: The questions

    private var questionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(entries) { item in
                    questionRow(item)
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func questionRow(_ item: FAQEntry) -> some View {
        let isSelected = item.id == entry.id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = item.id }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? RigTheme.amber : RigTheme.textMuted)
                    .frame(width: 17)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.question)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isSelected ? RigTheme.textPrimary
                                                    : RigTheme.textPrimary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.short)
                        .font(.system(size: 9.5))
                        .foregroundStyle(RigTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(alignment: .leading) {
                // The selected row is marked by a bar and a wash rather than a
                // filled tile: this is a list of text, and a solid amber row
                // would be the loudest thing on a page whose subject is prose.
                if isSelected {
                    HStack(spacing: 0) {
                        Rectangle().fill(RigTheme.amber).frame(width: 2.5)
                        Rectangle().fill(RigTheme.amber.opacity(0.08))
                    }
                }
            }
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(RigTheme.hairline).frame(height: 1).padding(.leading, 18)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.question) \(item.short)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: The answer

    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.question)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(RigTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(entry.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 11))
                        .foregroundStyle(RigTheme.textPrimary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !entry.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(entry.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .heavy).monospacedDigit())
                                    .foregroundStyle(.black)
                                    .frame(width: 15, height: 15)
                                    .background(Circle().fill(RigTheme.amber))
                                Text(step)
                                    .font(.system(size: 11))
                                    .foregroundStyle(RigTheme.textPrimary.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                if let note = entry.note {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RigTheme.trim)
                            .padding(.top, 1)
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(RigTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .rigCard(cornerRadius: 9)
                }
            }
            // CAPPED, and generously: an answer is READ rather than scanned, so
            // it gets a longer measure than a settings row's 430 — but the page
            // is 854 pt wide and a line allowed to fill that is unreadable.
            .frame(maxWidth: 470, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        // Keyed on the entry so switching questions starts at the top of the new
        // answer rather than halfway down it.
        .id(entry.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.question) "
                            + entry.paragraphs.joined(separator: " ") + " "
                            + entry.steps.joined(separator: " ") + " "
                            + (entry.note ?? ""))
    }
}

#Preview(traits: .landscapeLeft) {
    FAQView(onClose: {})
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
