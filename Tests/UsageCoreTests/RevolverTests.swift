import Foundation
import Testing
@testable import UsageCore

/// Fixtures are real `revo` answers (schema 1) with the home directory replaced; the ls one has a limit added.
@Suite struct RevolverTests {
    private func decode<T: Decodable>(_ json: String, status: Int32 = 0) throws -> T {
        try Revo.decode((status, Data(json.utf8)))
    }

    private func block(_ id: String, on: Bool = true, model: String = "default", effort: String = "high") -> RevoBlock {
        RevoBlock(id: id, engine: "codex", model: model, effort: effort, on: on, takesOver: "-")
    }

    private func draft(_ chain: RevoChain) -> RevoDraft { RevoDraft(chain) }

    @Test func parsesChainSkippingUnknownFields() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        #expect(chain.configPath == "/Users/u/.config/revolver/chain.json")
        #expect(chain.configRev.count == 64)
        #expect(chain.chain.map(\.id) == ["sol", "astra", "gemini", "fable"])
        #expect(chain.chain[0] == RevoBlock(id: "sol", engine: "codex", model: "gpt-6.1-sol", effort: "max", on: true,
                                            takesOver: "-"))
        #expect(chain.chain.map(\.on) == [true, false, true, true])
        #expect(chain.settings?.reviewRounds == 2)
        #expect(chain.settings?.lang == "ru")
        #expect(chain.state["sol"] == RevoBlockState(limitUntil: 1792745400, active: true))
        #expect(chain.state["gemini"] == RevoBlockState(limitUntil: nil, active: false))
    }

    @Test func revoWithoutSettingsStillParses() throws {
        let chain: RevoChain = try decode("""
            {"schema": 1, "ok": true, "config_path": "/c.json", "config_rev": "defaults",
             "chain": [{"id": "a", "engine": "agy", "model": "m", "effort": "low", "on": false, "takes_over": "limit",
                        "future": 1}]}
            """)
        #expect(chain.settings == nil)
        #expect(chain.state.isEmpty)
        #expect(chain.chain.first?.takesOver == "limit")
    }

    @Test func parsesEngines() throws {
        struct Answer: Decodable { let engines: [RevoEngine] }
        let engines = try Revo.decode((0, fixture("revo_engines"))) as Answer
        #expect(engines.engines.map(\.name) == ["codex", "agy", "claude"])
        #expect(engines.engines.allSatisfy { $0.models.first == "default" })
        #expect(engines.engines[1].display == "Gemini")
        #expect(engines.engines[1].efforts == ["low", "medium", "high"])
        #expect(engines.engines[0].customModel)
    }

    @Test func parsesApplyDiffWithMixedValues() throws {
        let result: RevoApplyResult = try Revo.decode((0, fixture("revo_apply_check")))
        #expect(result.check)
        #expect(result.configRev == "defaults")
        #expect(result.diff.order == RevoDiff.Order(old: ["codex", "claude", "agy"], new: ["agy", "codex", "claude"]))
        #expect(result.diff.changes == [
            RevoChange(id: "codex", field: "effort", old: .string("high"), new: .string("xhigh")),
            RevoChange(id: "claude", field: "on", old: .bool(true), new: .bool(false)),
        ])
        #expect(result.diff.settings == [
            RevoChange(id: nil, field: "review_rounds", old: .int(2), new: .int(3)),
            RevoChange(id: nil, field: "lang", old: nil, new: .string("ru")),
        ])
    }

    @Test func errorObjectIsTranslatedByCode() throws {
        let failure = #expect(throws: RevoFailure.self) {
            let _: RevoApplyResult = try Revo.decode((2, try fixture("revo_error_effort")))
        }
        guard case .failed(let error, let status)? = failure else { Issue.record("not .failed"); return }
        #expect(status == 2)
        #expect(error.code == "invalid_effort")
        #expect(error.value == .string("max"))
        #expect(failure?.text == "agy: effort max is not supported")
    }

    @Test func unknownCodeFallsBackToMessage() {
        let failure = #expect(throws: RevoFailure.self) {
            let _: RevoChain = try decode("""
                {"schema": 1, "ok": false, "error": {"code": "something_new", "block": null, "field": null,
                 "value": [1, 2], "message": "revo explains it"}}
                """, status: 2)
        }
        #expect(failure?.text == "revo explains it")
        #expect(failure?.isConfigChanged == false)
    }

    @Test func otherSchemaOrUsageMeansOutdated() {
        #expect(throws: RevoFailure.outdated) {
            let _: RevoChain = try decode(#"{"schema": 2, "ok": true}"#)
        }
        #expect(throws: RevoFailure.outdated) {
            let _: RevoChain = try decode(#"{"ok": true, "chain": []}"#)
        }
        #expect(throws: RevoFailure.outdated) {
            let _: RevoChain = try decode("""
                {"schema": 1, "ok": false, "error": {"code": "usage", "block": null, "field": null, "value": null,
                 "message": "unexpected arguments"}}
                """, status: 2)
        }
    }

    @Test func notJSONOrFailedSuccessIsUnreadable() {
        #expect(throws: RevoFailure.unreadable(status: 1)) {
            let _: RevoChain = try decode("Traceback (most recent call last):", status: 1)
        }
        #expect(throws: RevoFailure.unreadable(status: 3)) {
            let _: RevoChain = try decode(#"{"schema": 1, "ok": true}"#, status: 3)
        }
    }

    @Test func opsHoldOnlyWhatChanged() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        let old = draft(chain)
        #expect(RevoOps.between(old, old).isEmpty)

        var new = old
        new.blocks.swapAt(0, 2)
        new.blocks[0].on = false                // gemini
        new.blocks[1].effort = "xhigh"          // astra
        new.blocks[1].effort = "high"           // back to the original: no edit
        new.blocks[2].model = "gpt-6-astra"     // sol
        new.settings?.lang = nil
        let ops = RevoOps.between(old, new)
        #expect(ops.order == ["gemini", "astra", "sol", "fable"])
        #expect(ops.set == ["gemini": .init(on: false), "sol": .init(model: "gpt-6-astra")])
        #expect(ops.reviewRounds == nil)
        #expect(ops.lang == .some(nil))
        #expect(String(decoding: ops.json(base: "rev1"), as: UTF8.self) == """
            {"base":"rev1","order":["gemini","astra","sol","fable"],"schema":1,"set":{"gemini":{"on":false},\
            "sol":{"model":"gpt-6-astra"}},"settings":{"lang":null}}
            """)
    }

    @Test func settingsOpsAreSentOnlyWhenChanged() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        var new = draft(chain)
        new.settings?.reviewRounds = 5
        let ops = RevoOps.between(draft(chain), new)
        #expect(ops.lang == nil)
        #expect(String(decoding: ops.json(base: "b"), as: UTF8.self)
                == #"{"base":"b","schema":1,"settings":{"review_rounds":5}}"#)
    }

    @Test func editsAreReappliedToAChangedChain() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        var edited = draft(chain)
        edited.blocks.reverse()
        edited.blocks[0].on = false   // fable
        edited.settings?.reviewRounds = 4
        let ops = RevoOps.between(draft(chain), edited)

        // Someone removed astra meanwhile: the order no longer fits and is dropped, the field edit stays.
        var changed = draft(chain)
        changed.blocks.removeAll { $0.id == "astra" }
        changed.settings?.lang = "en"
        let rebased = ops.applied(to: changed)
        #expect(rebased.blocks.map(\.id) == ["sol", "gemini", "fable"])
        #expect(rebased.blocks.map(\.on) == [true, true, false])
        #expect(rebased.settings?.reviewRounds == 4)
        #expect(rebased.settings?.lang == "en")

        // Nothing changed elsewhere: the edits give exactly the edited draft.
        #expect(ops.applied(to: draft(chain)) == edited)
    }

    @Test func fakeRevoGetsLanguageRootDirectoryAndBusyCode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("revo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("revo")
        // Echoes its stdin size, REVO_LANG and working directory in the message, then exits with "busy".
        try """
            #!/bin/sh
            n=$(wc -c | tr -d ' ')
            printf '{"schema":1,"ok":false,"error":{"code":"busy","block":null,"field":null,"value":null,"message":"%s %s %s"}}' "$n" "$REVO_LANG" "$(pwd)"
            exit 5
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let ops = RevoOps(set: ["a": .init(on: true)])
        let failure = await #expect(throws: RevoFailure.self) {
            try await Revo.apply(script.path, ops, base: "x", check: false)
        }
        guard case .failed(let error, let status)? = failure else { Issue.record("not .failed"); return }
        #expect(status == 5)
        #expect(error.message == "\(ops.json(base: "x").count) en /")
        #expect(failure?.text == "The review chain is being changed by another process. Try again.")
    }

    /// Against a real revo, only on request: `REVO_LIVE=<revo> ./test.sh --filter liveRevo`. It writes, so point it
    /// at a wrapper that sets a temp `XDG_CONFIG_HOME`, never at the revo of your real chain.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REVO_LIVE"] != nil))
    func liveRevo() async throws {
        let revo = try #require(ProcessInfo.processInfo.environment["REVO_LIVE"])
        try await Revo.checkVersion(revo)
        let chain = try await Revo.list(revo)
        let engines = try await Revo.engines(revo)
        #expect(Set(chain.chain.map(\.engine)).isSubset(of: Set(engines.map(\.name))))

        var edited = RevoDraft(chain)
        edited.blocks[0].on.toggle()
        edited.blocks.reverse()
        edited.settings?.lang = "ru"
        let ops = RevoOps.between(RevoDraft(chain), edited)
        let check = try await Revo.apply(revo, ops, base: chain.configRev, check: true)
        #expect(check.check && check.configRev == chain.configRev)
        #expect(check.diff.order?.new == edited.blocks.map(\.id))
        #expect(check.diff.changes.map(\.field) == ["on"])

        let written = try await Revo.apply(revo, ops, base: check.configRev, check: false)
        #expect(!written.check && written.configRev != chain.configRev)
        let failure = await #expect(throws: RevoFailure.self) {
            try await Revo.apply(revo, ops, base: chain.configRev, check: false)
        }
        #expect(failure?.isConfigChanged == true)
        if case .failed(_, let status)? = failure { #expect(status == 4) }

        let after = try await Revo.list(revo)
        #expect(RevoDraft(after) == edited)
        // Back to the start: the same edits in reverse, lang removed again.
        let back = RevoOps.between(RevoDraft(after), RevoDraft(chain))
        #expect(back.lang == .some(chain.settings?.lang))
        _ = try await Revo.apply(revo, back, base: after.configRev, check: false)
        #expect(RevoDraft(try await Revo.list(revo)) == RevoDraft(chain))
    }

    @Test func locatePrefersTheChosenPath() {
        #expect(Revo.locate(custom: "/bin/sh") == "/bin/sh")
        #expect(Revo.locate(custom: "/nonexistent/revo") == ProcessRunner.locate(Revo.candidates))
    }
}
