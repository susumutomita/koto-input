/// composition のかな形態（Tab 連打での巡回対象、Issue 41）。
///
/// Tab 1 回目のひらがな化（RomajiKanaConverter.normalize）後の表示形態を表し、
/// 以降の Tab でひらがな ⇄ カタカナを巡回する。CompositionState.kanaCycleForm
/// が nil のときは非巡回で、次の normalizeToKana はローマ字→ひらがな化から
/// 始まる。
public enum KanaForm: Equatable, Sendable {
    case hiragana
    case katakana
}
