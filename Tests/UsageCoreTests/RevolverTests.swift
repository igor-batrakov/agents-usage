import Foundation
import Testing
@testable import UsageCore

/// Fixtures are real `revo` answers (schema 2) with the home directory replaced; the ls one is a chain without
/// roles in the file (revo derives them) with a Codex limit added.
@Suite struct RevolverTests {
    private func decode<T: Decodable>(_ json: String, status: Int32 = 0) throws -> T {
        try Revo.decode((status, Data(json.utf8)))
    }

    private func block(_ id: String, required: Bool = false, on: Bool = true) -> RevoBlock {
        RevoBlock(id: id, engine: "codex", model: "default", effort: "high", on: on,
                  role: required ? RevoRole.required : RevoRole.fallback,
                  takesOver: required ? RevoTakesOver.none : RevoTakesOver.anyFail)
    }

    private func draft(_ chain: RevoChain) -> RevoDraft { RevoDraft(chain) }

    private func json(_ ops: RevoOps, base: String = "b") -> String { String(decoding: ops.json(base: base), as: UTF8.self) }

    @Test func parsesChainWithDerivedRoles() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        #expect(chain.configPath == "/Users/u/.config/revolver/chain.json")
        #expect(chain.configRev.count == 64)
        #expect(chain.chain.map(\.id) == ["sol", "astra", "gemini", "fable"])
        #expect(chain.chain[0] == RevoBlock(id: "sol", engine: "codex", model: "gpt-6.1-sol", effort: "max", on: true,
                                            role: "required", takesOver: "-"))
        #expect(chain.chain.map(\.role) == ["required", "fallback", "fallback", "fallback"])
        #expect(chain.chain.map(\.on) == [true, false, true, true])
        #expect(chain.settings?.reviewRounds == 2)
        #expect(chain.settings?.lang == "ru")
        #expect(chain.settings?.missingReview == "ask")
        #expect(chain.state["sol"] == RevoBlockState(limitUntil: 1792745400, active: true))
        #expect(chain.state["gemini"] == RevoBlockState(limitUntil: nil, active: false))
        let before = Date(timeIntervalSince1970: 1792745000), after = Date(timeIntervalSince1970: 1792745500)
        #expect(chain.limit("sol", now: before) == Date(timeIntervalSince1970: 1792745400))
        #expect(chain.limit("sol", now: after) == nil)
        #expect(chain.limit("gemini", now: before) == nil)
    }

    @Test func missingOptionalFieldsGetDefaults() throws {
        let chain: RevoChain = try decode("""
            {"schema": 2, "ok": true, "config_path": "/c.json", "config_rev": "defaults",
             "chain": [{"id": "a", "engine": "agy", "model": "m", "effort": "low", "on": false, "takes_over": "limit",
                        "role": "fallback", "future": 1}],
             "settings": {"review_rounds": 3}}
            """)
        #expect(chain.settings?.missingReview == "ask")
        #expect(chain.settings?.lang == nil)
        #expect(chain.state.isEmpty)
        #expect(chain.chain.first?.takesOver == "limit")
    }

    @Test func parsesEnginesAndChecksModelNames() throws {
        struct Answer: Decodable { let engines: [RevoEngine] }
        let engines = try Revo.decode((0, fixture("revo_engines"))) as Answer
        #expect(engines.engines.map(\.name) == ["codex", "agy", "claude"])
        #expect(engines.engines.allSatisfy { $0.models.first == "default" })
        let agy = engines.engines[1]
        #expect(agy.display == "Gemini")
        #expect(agy.efforts == ["low", "medium", "high"])
        #expect(agy.modelPattern == "^[A-Za-z0-9._-]+$")
        #expect(agy.accepts("gemini-5.0-pro"))
        #expect(!agy.accepts("gemini 5"))
        #expect(!agy.accepts(""))
        #expect(agy.defaultEffort == "high")
    }

    @Test func parsesApplyDiffWithAddedAndRemoved() throws {
        let result: RevoApplyResult = try Revo.decode((0, fixture("revo_apply_check")))
        #expect(result.check)
        #expect(result.diff.order == RevoDiff.Order(old: ["sol", "astra", "gemini", "fable"],
                                                    new: ["sol", "gemini", "fable", "opus"]))
        #expect(result.diff.changes == [RevoChange(id: "fable", field: "takes_over", old: .string("limit"),
                                                   new: .string("any_fail"))])
        #expect(result.diff.added == [RevoBlock(id: "opus", engine: "claude", model: "claude-opus-5-5", effort: "high",
                                                on: true, role: "required", takesOver: "-")])
        #expect(result.diff.removed == ["astra"])
        #expect(result.diff.settings == [RevoChange(id: nil, field: "missing_review", old: .string("ask"),
                                                    new: .string("note"))])
    }

    @Test func errorObjectIsTranslatedByCode() throws {
        let failure = #expect(throws: RevoFailure.self) {
            let _: RevoApplyResult = try Revo.decode((2, try fixture("revo_error_effort")))
        }
        guard case .failed(let error, let status)? = failure else { Issue.record("not .failed"); return }
        #expect(status == 2)
        #expect(error.code == "invalid_effort")
        #expect(error.value == .string("max"))
        #expect(failure?.text == "gemini: effort max is not supported")

        let role = #expect(throws: RevoFailure.self) {
            let _: RevoApplyResult = try Revo.decode((2, try fixture("revo_error_role")))
        }
        #expect(role?.text == "new config: block 3 — role 'boss', allowed required, fallback")
    }

    @Test func unknownCodeFallsBackToMessage() {
        let failure = #expect(throws: RevoFailure.self) {
            let _: RevoChain = try decode("""
                {"schema": 2, "ok": false, "error": {"code": "something_new", "block": null, "field": null,
                 "value": [1, 2], "message": "revo explains it"}}
                """, status: 2)
        }
        #expect(failure?.text == "revo explains it")
        #expect(failure?.isConfigChanged == false)
    }

    @Test func otherSchemaOrUsageMeansOutdated() {
        #expect(throws: RevoFailure.outdated) {
            let _: RevoChain = try decode(#"{"schema": 1, "ok": true}"#)
        }
        #expect(throws: RevoFailure.outdated) {
            let _: RevoChain = try decode(#"{"ok": true, "chain": []}"#)
        }
        #expect(throws: RevoFailure.outdated) {
            let _: RevoChain = try decode("""
                {"schema": 2, "ok": false, "error": {"code": "usage", "block": null, "field": null, "value": null,
                 "message": "unexpected arguments"}}
                """, status: 2)
        }
    }

    @Test func aNewerSchemaAsksToUpdateTheApp() async throws {
        #expect(throws: RevoFailure.newer) {
            let _: RevoChain = try decode(#"{"schema": 3, "ok": true}"#)
        }
        // `version --json` of a revo that speaks only schema 3, and of one that speaks both.
        func revo(_ schemas: String) throws -> String {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("revo-\(UUID().uuidString)").path
            try "#!/bin/sh\necho '{\"schema\": 3, \"ok\": true, \"schemas\": \(schemas)}'\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let failure = await #expect(throws: RevoFailure.newer) { try await Revo.checkVersion(try revo("[3]")) }
        #expect(failure?.text == "This revo is newer than the app. Update Agents Usage: Settings → About.")
        try await Revo.checkVersion(try revo("[2, 3]"))
        await #expect(throws: RevoFailure.outdated) { try await Revo.checkVersion(try revo("[1]")) }
    }

    @Test func notJSONOrFailedSuccessIsUnreadable() {
        #expect(throws: RevoFailure.unreadable(status: 1)) {
            let _: RevoChain = try decode("Traceback (most recent call last):", status: 1)
        }
        #expect(throws: RevoFailure.unreadable(status: 3)) {
            let _: RevoChain = try decode(#"{"schema": 2, "ok": true}"#, status: 3)
        }
    }

    @Test func noEditsSendNothing() throws {
        let old = draft(try Revo.decode((0, fixture("revo_ls"))))
        #expect(RevoOps.between(old, old).isEmpty)
    }

    @Test func editsCarryOnlyChangesPlusEveryRole() throws {
        let old = draft(try Revo.decode((0, fixture("revo_ls"))))
        var new = old
        new.blocks.swapAt(0, 2)                 // gemini, astra, sol, fable
        new.blocks[0].on = false                // gemini
        new.blocks[1].effort = "xhigh"          // astra
        new.blocks[1].effort = "high"           // back to the original: no edit
        new.blocks[2].model = "gpt-6-astra"     // sol
        new.settings?.lang = nil
        let ops = RevoOps.between(old, new)
        #expect(ops.remove.isEmpty && ops.add.isEmpty)
        #expect(ops.order == ["gemini", "astra", "sol", "fable"])
        #expect(ops.set == ["gemini": .init(on: false), "sol": .init(model: "gpt-6-astra")])
        #expect(ops.roles == ["sol": "required", "astra": "fallback", "gemini": "fallback", "fable": "fallback"])
        #expect(ops.lang == .some(nil))
        #expect(json(ops, base: "rev1") == """
            {"base":"rev1","order":["gemini","astra","sol","fable"],"schema":2,"set":{"astra":{"role":"fallback"},\
            "fable":{"role":"fallback"},"gemini":{"on":false,"role":"fallback"},\
            "sol":{"model":"gpt-6-astra","role":"required"}},"settings":{"lang":null}}
            """)
    }

    @Test func roleChangeSendsItsCondition() throws {
        let old = draft(try Revo.decode((0, fixture("revo_ls"))))
        var new = old
        new.blocks[2].role = RevoRole.required  // gemini
        new.blocks[2].takesOver = RevoTakesOver.none
        new.settings?.missingReview = "note"
        let ops = RevoOps.between(old, new)
        #expect(ops.set["gemini"] == .init(role: "required", takesOver: "-"))
        #expect(ops.missingReview == "note")
        #expect(json(ops).contains(#""settings":{"missing_review":"note"}"#))
    }

    @Test func addedBlocksGetFreeIDsAndRemovedAreListed() throws {
        let old = draft(try Revo.decode((0, fixture("revo_ls"))))
        var new = old
        new.blocks.removeAll { $0.id == "astra" }
        let opus = RevoBlock(id: RevoDraft.newID(), engine: "claude", model: "claude-opus-5-5", effort: "high",
                             role: RevoRole.required, takesOver: RevoTakesOver.none)
        new.blocks.append(opus)
        var ops = RevoOps.between(old, new)
        #expect(ops.remove == ["astra"])
        #expect(ops.add.map(\.id) == ["opus"])
        #expect(ops.add.first?.role == "required")
        #expect(ops.order == nil)   // added at the end: the natural order
        #expect(ops.set.isEmpty)
        #expect(ops.roles.keys.sorted() == ["fable", "gemini", "sol"])
        #expect(json(ops).contains(#""add":[{"effort":"high","engine":"claude","id":"opus","model":"claude-opus-5-5","on":true,"role":"required","takes_over":"-"}]"#))
        #expect(json(ops).contains(#""remove":["astra"]"#))

        // In the middle, the order is sent with the final id.
        new.blocks.insert(new.blocks.removeLast(), at: 1)
        ops = RevoOps.between(old, new)
        #expect(ops.order == ["sol", "opus", "gemini", "fable"])
    }

    @Test func freeIDsComeFromTheModel() {
        func id(_ model: String, _ engine: String = "claude", taken: Set<String> = []) -> String {
            RevoDraft.freeID(for: RevoBlock(id: "+x", engine: engine, model: model, effort: "high"), taken: taken)
        }
        #expect(id("claude-opus-5-5") == "opus")
        #expect(id("claude-opus-5-5", taken: ["opus", "opus2"]) == "opus3")
        #expect(id("gpt-6.1-sol", "codex") == "sol")
        #expect(id("gemini-3.8-flash", "agy") == "flash")
        #expect(id("default", "agy") == "agy")
        #expect(id("default", "claude", taken: ["claude"]) == "claude2")
    }

    @Test func editsAreReappliedToAChangedChain() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        var edited = draft(chain)
        edited.blocks.reverse()
        edited.blocks[0].on = false   // fable
        edited.blocks.removeAll { $0.id == "gemini" }
        edited.blocks.append(RevoBlock(id: RevoDraft.newID(), engine: "claude", model: "claude-opus-5-5", effort: "high"))
        edited.settings?.reviewRounds = 4
        let ops = RevoOps.between(draft(chain), edited)

        // Someone removed astra meanwhile: the order no longer fits and is dropped, the other edits stay.
        var changed = draft(chain)
        changed.blocks.removeAll { $0.id == "astra" }
        changed.settings?.lang = "en"
        let rebased = ops.applied(to: changed)
        #expect(rebased.blocks.map(\.id) == ["sol", "fable", "opus"])
        #expect(rebased.blocks.map(\.on) == [true, false, true])
        #expect(rebased.settings?.reviewRounds == 4)
        #expect(rebased.settings?.lang == "en")

        // Nothing changed elsewhere: the same chain as edited, the new block with its final id.
        var expected = edited
        expected.blocks[expected.blocks.count - 1].id = "opus"
        #expect(ops.applied(to: draft(chain)) == expected)
        // And applying them again gives no further edits.
        #expect(RevoOps.between(ops.applied(to: draft(chain)), expected).isEmpty)
    }

    @Test func rebaseDoesNotReplayTheSentRoles() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        var edited = draft(chain)
        edited.settings?.reviewRounds = 5
        let ops = RevoOps.between(draft(chain), edited)
        #expect(ops.roles["sol"] == "required")
        // Meanwhile sol became a fallback elsewhere: the rebase keeps that, and only the rounds change.
        var changed = draft(chain)
        changed.blocks[0].role = RevoRole.fallback
        changed.blocks[0].takesOver = RevoTakesOver.limit
        let rebased = ops.applied(to: changed)
        #expect(rebased.blocks[0].role == "fallback" && rebased.blocks[0].takesOver == "limit")
        #expect(rebased.settings?.reviewRounds == 5)
    }

    @Test func aNewBlockSurvivesItsIDBeingTaken() throws {
        let chain: RevoChain = try Revo.decode((0, fixture("revo_ls")))
        var edited = draft(chain)
        let mine = RevoBlock(id: RevoDraft.newID(), engine: "claude", model: "claude-opus-5-5", effort: "high")
        edited.blocks.append(mine)
        let ops = RevoOps.between(draft(chain), edited)
        #expect(ops.add.map(\.id) == ["opus"])

        // Someone else added another "opus": ours stays, new again, to get a free id on the next Apply.
        var changed = draft(chain)
        changed.blocks.append(RevoBlock(id: "opus", engine: "codex", model: "gpt-opus", effort: "low"))
        let rebased = ops.applied(to: changed)
        #expect(rebased.blocks.count == 6)
        let ours = try #require(rebased.blocks.last)
        #expect(RevoDraft.isNew(ours.id) && ours.engine == "claude")
        #expect(RevoOps.between(changed, rebased).add.map(\.id) == ["opus2"])

        // The very same reviewer under that id (our own write): nothing to add.
        var written = draft(chain)
        written.blocks.append(ops.add[0])
        #expect(ops.applied(to: written).blocks.count == 5)
    }

    @Test func chainRulesForTheTab() {
        // A required, B and C fallbacks, D required, E a disabled fallback.
        let chain = [block("A", required: true), block("B"), block("C"), block("D", required: true), block("E", on: false)]
        #expect(chain.hasEnabledRequired)
        #expect(chain.coveredFirst(at: 1)?.id == "A")
        #expect(chain.coveredFirst(at: 2)?.id == "A")
        #expect(chain.coveredFirst(at: 0) == nil)
        #expect(chain.warning(at: 0) == nil)
        #expect(chain.warning(at: 3) == .noFallback)
        #expect(chain.warning(at: 4) == nil)   // disabled: nothing to warn about

        let upsideDown = [block("F"), block("A", required: true)]
        #expect(upsideDown.warning(at: 0) == .neverRuns)
        #expect(upsideDown.warning(at: 1) == .noFallback)
        #expect(![block("A", required: true, on: false), block("B")].hasEnabledRequired)
    }

    @Test func fallbacksCoverLimitedRequiredTopDown() {
        let chain = [block("A", required: true), block("B"), block("C"), block("D", required: true), block("E", on: false)]
        // B goes to A; C is above D, so nobody is left for D.
        let both = chain.cover(limited: ["A", "D"])
        #expect(both.map(\.required.id) == ["A", "D"])
        #expect(both.map { $0.by?.id } == ["B", nil])
        // B is on a limit itself: C steps in.
        #expect(chain.cover(limited: ["A", "B"]).map { $0.by?.id } == ["C"])
        #expect(chain.cover(limited: []).isEmpty)
    }

    @Test func fakeRevoGetsLanguageRootDirectoryAndBusyCode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("revo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("revo")
        // Echoes its stdin size, REVO_LANG and working directory in the message, then exits with "busy".
        try """
            #!/bin/sh
            n=$(wc -c | tr -d ' ')
            printf '{"schema":2,"ok":false,"error":{"code":"busy","block":null,"field":null,"value":null,"message":"%s %s %s"}}' "$n" "$REVO_LANG" "$(pwd)"
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

    @Test func shellPathSkipsProfileNoise() {
        #expect(Revo.shellPath("Welcome back!\n\u{1b}[0m\n  /Users/me/bin/revo  \n\n") == "/Users/me/bin/revo")
        #expect(Revo.shellPath("/usr/local/share/motd\n/Users/me/My Tools/revo\n") == "/Users/me/My Tools/revo")
        #expect(Revo.shellPath("alias revo='python3 -m revolver'\n") == nil)
        #expect(Revo.shellPath("") == nil)
    }

    /// A stand-in shell that prints profile noise, then the answer, and exits with `status`.
    private func fakeShell(status: Int) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)").path
        let script = "#!/bin/sh\necho 'zsh profile says hi'\necho /opt/tools/revo\nexit \(status)\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func fromShellTakesTheLastPath() async throws {
        #expect(await Revo.fromShell(try fakeShell(status: 0)) == "/opt/tools/revo")
    }

    @Test func fromShellIgnoresAFailedLookup() async throws {
        #expect(await Revo.fromShell(try fakeShell(status: 1)) == nil)
    }

    /// The real login shell, only on request: `REVO_SHELL=1 ./test.sh --filter liveShell`. Runs your shell profile.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REVO_SHELL"] != nil))
    func liveShell() async throws {
        let found = try #require(await Revo.fromShell())
        print("login shell revo:", found)
        try await Revo.checkVersion(found)
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
        #expect(chain.chain.count >= 2)

        // Remove the last block, reverse the rest, turn the new first one around, add a reviewer at the end.
        var edited = RevoDraft(chain)
        let removed = edited.blocks.removeLast()
        edited.blocks.reverse()
        edited.blocks[0].on.toggle()
        edited.blocks[0].role = RevoRole.required
        edited.blocks[0].takesOver = RevoTakesOver.none
        let engine = try #require(engines.last)
        edited.blocks.append(RevoBlock(id: RevoDraft.newID(), engine: engine.name, model: engine.models[0],
                                       effort: engine.defaultEffort))
        edited.settings?.lang = chain.settings?.lang == nil ? "ru" : nil
        edited.settings?.missingReview = chain.settings?.missingReview == "note" ? "ask" : "note"
        let ops = RevoOps.between(RevoDraft(chain), edited)
        let check = try await Revo.apply(revo, ops, base: chain.configRev, check: true)
        #expect(check.check && check.configRev == chain.configRev)
        #expect(check.diff.removed == [removed.id])
        #expect(check.diff.added.map(\.id) == ops.add.map(\.id))
        #expect(check.diff.order?.new == ops.order)
        #expect(check.diff.settings.map(\.field).contains("missing_review"))

        let written = try await Revo.apply(revo, ops, base: check.configRev, check: false)
        #expect(!written.check && written.configRev != chain.configRev)
        let failure = await #expect(throws: RevoFailure.self) {
            try await Revo.apply(revo, ops, base: chain.configRev, check: false)
        }
        #expect(failure?.isConfigChanged == true)
        if case .failed(_, let status)? = failure { #expect(status == 4) }

        let after = try await Revo.list(revo)
        #expect(RevoDraft(after) == ops.applied(to: RevoDraft(chain)))
        // Back to the start: the removed block comes back, the added one goes, lang is as it was.
        let back = RevoOps.between(RevoDraft(after), RevoDraft(chain))
        #expect(back.lang == .some(chain.settings?.lang))
        #expect(back.add.map(\.id) == [removed.id])
        _ = try await Revo.apply(revo, back, base: after.configRev, check: false)
        #expect(RevoDraft(try await Revo.list(revo)) == RevoDraft(chain))
    }

    @Test func locatePrefersTheChosenPath() {
        #expect(Revo.locate(custom: "/bin/sh") == "/bin/sh")
        #expect(Revo.locate(custom: "/nonexistent/revo") == ProcessRunner.locate(Revo.candidates))
    }
}
