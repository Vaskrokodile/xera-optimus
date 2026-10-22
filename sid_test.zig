const std = @import("std");
const mp = @import("src/mp.zig");

pub fn main() !void {
    var buf: [160]u8 = undefined;
    const cases = [_][]const u8{
        "xmp-192.168.1.5-7777-a3f9c1",
        "  xmp-172.20.10.3\xE2\x80\x937777\xE2\x80\x93fd6bb7",
        "  xmp-172.20.10.3\xE2\x80\x93\xC2\xA07777\xE2\x80\x93fd6bb7",
        "xmp-172.20.10.3\xE2\x88\x927777\xE2\x88\x92abc123",
        "xmp-10.0.0.1 - 7777 - deadbeef",
        // double-mojibake, exactly as seen pasted through a CP1252 host:
        // '–' became chars â,\x80,\x93 and NBSP became Â,\xa0
        "xmp-172.20.10.3\xC3\xA2\xC2\x80\xC2\x93\xC3\x82\xC2\xA07777\xC3\xA2\xC2\x80\xC2\x9320d1e9",
    };
    for (cases) |c| {
        const p = mp.parseSessionId(&buf, c) catch |e| {
            std.debug.print("FAIL {s}\n  -> {s}\n", .{ c, @errorName(e) });
            continue;
        };
        std.debug.print("OK   ip={s} port={d} key={s}\n", .{ p.ip, p.port, p.key });
    }
}
