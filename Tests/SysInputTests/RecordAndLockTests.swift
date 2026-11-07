import Darwin
import Foundation
import Testing
import TalkTalkAudio
import TalkTalkCore
import TalkTalkTestSupport

@Suite(.temporaryFiles) struct RecordStoreTests {
    private func sample() -> SysInputRecord {
        SysInputRecord(original: .init(Devs.usb), writerBundleID: BuildFlavor.dev.rawValue,
                       executablePath: "/Applications/TalkTalk-Dev.app/Contents/MacOS/TalkTalk", guardPID: 77,
                       meetingApps: ["us.zoom.xos"])
    }

    @Test func writesMode0600AtomicallyWithFsync() throws {
        let paths = try tempPaths()
        let synced = EventTrail()
        let store = SysInputRecordStore(paths: paths, onFsync: { synced.add($0) })
        #expect(!store.exists)
        #expect(store.read() == nil)
        let r = sample()
        try store.write(r)
        #expect(store.exists)
        #expect(mode(of: paths.record.path) == 0o600)
        #expect(store.read() == r)
        // fsync on the temp file (before the rename), then on the directory.
        #expect(synced.all.count == 2)
        #expect(synced.all.first?.contains(".sysinput-restore.json.") == true)
        #expect(synced.all.last == paths.directory.path)
        // No temp file left behind; overwriting keeps 0600 and replaces the content.
        var r2 = r
        r2.guardPID = 78
        r2.replacementUID = Devs.builtIn.uid
        try store.write(r2)
        #expect(store.read() == r2)
        #expect(mode(of: paths.record.path) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.directory.path)
        #expect(names == ["sysinput-restore.json"])
        store.delete()
        #expect(!store.exists)
    }

    @Test func atomicRenameNeverLeavesAPartialRecord() throws {
        let paths = try tempPaths()
        let store = SysInputRecordStore(paths: paths)
        try store.write(sample())
        let before = try Data(contentsOf: paths.record)
        // A stale temp file from a crash does not break the next write.
        let stale = paths.directory.appendingPathComponent(".sysinput-restore.json.\(getpid()).tmp")
        try Data("garbage".utf8).write(to: stale)
        var r = sample()
        r.meetingApps = ["com.microsoft.teams2"]
        try store.write(r)
        #expect(store.read()?.meetingApps == ["com.microsoft.teams2"])
        #expect(try Data(contentsOf: paths.record) != before)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func unreadableRecordStillCountsAsARecord() throws {
        let paths = try tempPaths()
        try Data("{not json".utf8).write(to: paths.record)
        let r = SysInputRecordStore(paths: paths).read()
        #expect(r == .unreadable())
        // Nothing known about the original → the restore order (built-in) applies.
        let t = SystemInputPlan.restoreTarget(original: r?.original, devices: [Devs.usb, Devs.builtIn, Devs.mic])
        #expect(t?.device == Devs.builtIn)
    }

    @Test func devAndReleaseShareOneRecord() {
        let p = SysInputPaths.standard()
        #expect(p.record.path.hasSuffix("Library/Application Support/TalkTalk/sysinput-restore.json"))
        #expect(p.lock.path.hasSuffix("Library/Application Support/TalkTalk/sysinput-restore.lock"))
        #expect(!p.record.path.contains(".dev"))
    }
}

@Suite(.temporaryFiles) struct LockTests {
    @Test func exclusiveAcrossOpenFileDescriptions() throws {
        let paths = try tempPaths()
        let a = SysInputLock(path: paths.lock.path)
        let b = SysInputLock(path: paths.lock.path)
        #expect(SysInputLock.isAvailable(path: paths.lock.path))
        #expect(a.tryAcquire())
        #expect(mode(of: paths.lock.path) == 0o600)
        #expect(!b.tryAcquire())
        #expect(!b.tryAcquire(timeout: 0.1))
        #expect(!SysInputLock.isAvailable(path: paths.lock.path))
        a.release()
        #expect(SysInputLock.isAvailable(path: paths.lock.path))
        #expect(b.tryAcquire())
        b.release()
    }

    @Test func descriptorIsCloseOnExecSoChildrenDoNotInheritIt() throws {
        let paths = try tempPaths()
        let lock = SysInputLock(path: paths.lock.path)
        #expect(lock.tryAcquire())
        defer { lock.release() }
        #expect(SysInputLock.hasCloseOnExec(lock.fd))
        let probe = "test -e /dev/fd/\(lock.fd)"
        // Plain spawn (what the engine launcher does): the lock is not there.
        let plain = try #require(Spawned.run("/bin/sh", ["-c", probe]))
        #expect(plain.wait(timeout: 10)?.code == 1)
        // Only addinherit_np passes it on (M0-T8 d6).
        let inherited = try #require(Spawned.run("/bin/sh", ["-c", probe], inherit: [lock.fd]))
        #expect(inherited.wait(timeout: 10)?.code == 0)
    }

    @Test func childKeepsTheFlockAfterTheParentIsKilled() throws {
        let paths = try tempPaths()
        let lock = SysInputLock(path: paths.lock.path)
        #expect(lock.tryAcquire())
        // "app" = sh, "guard" = its sleep child; both share our open file description.
        let app = try #require(Spawned.run("/bin/sh", ["-c", "sleep 300 & echo $!; wait"], inherit: [lock.fd]))
        let guardPID = try #require(Int32(app.readLine(app.stdout)))
        lock.detach()   // we are out of the picture: only "app" and "guard" hold it
        #expect(!SysInputLock.isAvailable(path: paths.lock.path))
        app.kill(SIGKILL)
        #expect(app.wait(timeout: 10)?.signal == SIGKILL)
        // kill -9 of the parent: the guard still holds the lock.
        #expect(!SysInputLock.isAvailable(path: paths.lock.path))
        _ = kill(guardPID, SIGKILL)
        // Both gone: the kernel drops it.
        #expect(waitUntil(5) { SysInputLock.isAvailable(path: paths.lock.path) })
    }

    @Test func verifyInheritedRejectsStrangers() throws {
        let paths = try tempPaths()
        let lock = SysInputLock(path: paths.lock.path)
        #expect(lock.tryAcquire())
        #expect(SysInputLock.verifyInherited(fd: lock.fd, path: paths.lock.path))
        // A different open of the same file (someone else holds the lock) fails.
        let other = open(paths.lock.path, O_RDWR | O_CLOEXEC)
        defer { close(other) }
        #expect(!SysInputLock.verifyInherited(fd: other, path: paths.lock.path))
        // Some other file, stdio, a closed fd.
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { close(null) }
        #expect(!SysInputLock.verifyInherited(fd: null, path: paths.lock.path))
        #expect(!SysInputLock.verifyInherited(fd: 2, path: paths.lock.path))
        #expect(!SysInputLock.verifyInherited(fd: 9999, path: paths.lock.path))
        lock.release()
    }
}
