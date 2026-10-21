//! Deterministic native flowchart layout. Feedback edges route outside nodes.
const std = @import("std");
const ui = @import("nanoui").ui;
const flow = @import("flowchart.zig");
pub const Geometry = struct { width: f32, height: f32, node_w: f32, node_h: f32, gap: f32, margin: f32, horizontal: bool, reverse: bool, size: f32 };
pub fn geometry(ctx: *ui.Context, graph: *const flow.Graph, size: f32) Geometry {
    const scale = size / 14;
    var w: f32 = 100 * scale;
    var h: f32 = 48 * scale;
    var gap: f32 = 64 * scale;
    for (graph.nodes) |node| w = @max(w, @min(190 * scale, ctx.text.layout(node.label, .{ .size = size }).width + 28 * scale));
    for (graph.nodes) |node| {
        const lines = ctx.text.wrap(node.label, .{ .size = size }, if (node.shape == .decision) w * 0.5 else w - 28 * scale);
        h = @max(h, @as(f32, @floatFromInt(lines.len)) * size * 1.5 + 24 * scale);
        if (node.shape == .decision) h = @max(h, 90 * scale);
    }
    for (graph.edges) |edge| gap = @max(gap, @min(210 * scale, ctx.text.layout(edge.label, .{ .size = size * 0.85 }).width + 24 * scale));
    const horizontal = graph.direction == .LR or graph.direction == .RL;
    const margin = (44 + @as(f32, @floatFromInt(graph.edges.len)) * 4) * scale;
    const rank_count: f32 = @floatFromInt(graph.ranks);
    const lane_count: f32 = @floatFromInt(graph.lanes);
    return .{
        .width = 2 * margin + if (horizontal) rank_count * w + (rank_count - 1) * gap else lane_count * (w + gap),
        .height = 2 * margin + if (horizontal) lane_count * (h + 48 * scale) else rank_count * h + (rank_count - 1) * gap,
        .node_w = w,
        .node_h = h,
        .gap = gap,
        .margin = margin,
        .horizontal = horizontal,
        .reverse = graph.direction == .RL or graph.direction == .BT,
        .size = size,
    };
}
pub fn nodeRect(g: Geometry, graph: *const flow.Graph, node: flow.Node) ui.Rect {
    const rank: f32 = @floatFromInt(if (g.reverse) graph.ranks - 1 - node.rank else node.rank);
    const lane: f32 = @floatFromInt(node.lane);
    return .{ .x = g.margin + if (g.horizontal) rank * (g.node_w + g.gap) else lane * (g.node_w + g.gap), .y = g.margin + if (g.horizontal) lane * (g.node_h + g.size * 48 / 14) else rank * (g.node_h + g.gap), .w = g.node_w, .h = g.node_h };
}
fn line(ctx: *ui.Context, clip: ui.Size, original_a: ui.Point, original_b: ui.Point, color: ui.Color, dotted: bool) void {
    // Clip before tessellating dashed/diagonal strokes: an enormous graph must
    // cost only visible work, not thousands of offscreen dash nodes per edge.
    var lo: f32 = 0;
    var hi: f32 = 1;
    const delta = ui.Point{ .x = original_b.x - original_a.x, .y = original_b.y - original_a.y };
    for ([_]f32{ original_a.x, original_a.y }, [_]f32{ delta.x, delta.y }, [_]f32{ clip.w, clip.h }) |start, d, limit| {
        if (d == 0) {
            if (start < 0 or start > limit) return;
            continue;
        }
        const t0 = -start / d;
        const t1 = (limit - start) / d;
        lo = @max(lo, @min(t0, t1));
        hi = @min(hi, @max(t0, t1));
        if (lo > hi) return;
    }
    const a = ui.Point{ .x = original_a.x + delta.x * lo, .y = original_a.y + delta.y * lo };
    const b = ui.Point{ .x = original_a.x + delta.x * hi, .y = original_a.y + delta.y * hi };
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = @max(@abs(dx), @abs(dy));
    if (length < 0.1) return;
    if (!dotted and (dx == 0 or dy == 0)) {
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) }, .width = .{ .px = @max(1.5, @abs(dx)) }, .height = .{ .px = @max(1.5, @abs(dy)) }, .background = color }, .none, null);
        return;
    }
    const step: f32 = if (dotted) 7 else 1.5;
    const steps: usize = @intFromFloat(@min(1024, @ceil(length / step)));
    for (0..steps) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = a.x + dx * t, .y = a.y + dy * t }, .width = .{ .px = if (dotted and dy == 0) 4 else 1.7 }, .height = .{ .px = if (dotted and dx == 0) 4 else 1.7 }, .background = color }, .none, null);
    }
}
fn shifted(p: ui.Point, origin: ui.Point) ui.Point {
    return .{ .x = p.x + origin.x, .y = p.y + origin.y };
}
pub fn draw(ctx: *ui.Context, graph: *const flow.Graph, g: Geometry, origin: ui.Point, clip: ui.Size, selected: bool) void {
    const color = ctx.theme.text.alpha(0.6);
    _ = ctx.leaf(.{ .absolute = true, .offset = origin, .width = .{ .px = g.width }, .height = .{ .px = g.height }, .radius = 8, .border = ctx.theme.border, .background = if (selected) ctx.theme.accent.alpha(0.12) else ctx.theme.text.alpha(0.025) }, .none, null);
    for (graph.edges, 0..) |edge, i| {
        const a = nodeRect(g, graph, graph.nodes[edge.from]);
        const b = nodeRect(g, graph, graph.nodes[edge.to]);
        const forward = graph.nodes[edge.to].rank > graph.nodes[edge.from].rank;
        const sign: f32 = if (g.reverse) -1 else 1;
        var points: [6]ui.Point = undefined;
        var count: usize = 4;
        var label_at: ui.Point = undefined;
        if (g.horizontal and forward) {
            points[0] = .{ .x = a.x + (if (g.reverse) @as(f32, 0) else a.w), .y = a.y + a.h / 2 };
            points[3] = .{ .x = b.x + (if (g.reverse) b.w else 0), .y = b.y + b.h / 2 };
            const middle = points[0].x + sign * g.gap / 2;
            points[1] = .{ .x = middle, .y = points[0].y };
            points[2] = .{ .x = middle, .y = points[3].y };
            label_at = .{ .x = middle, .y = points[3].y - 18 * g.size / 14 };
        } else if (!g.horizontal and forward) {
            points[0] = .{ .x = a.x + a.w / 2, .y = a.y + (if (g.reverse) @as(f32, 0) else a.h) };
            points[3] = .{ .x = b.x + b.w / 2, .y = b.y + (if (g.reverse) b.h else 0) };
            const middle = points[0].y + sign * g.gap / 2;
            points[1] = .{ .x = points[0].x, .y = middle };
            points[2] = .{ .x = points[3].x, .y = middle };
            label_at = points[2];
        } else {
            const lane = (18 + @as(f32, @floatFromInt(i)) * 4) * g.size / 14;
            if (g.horizontal) {
                points[0] = .{ .x = a.x + a.w / 2, .y = a.y };
                points[1] = .{ .x = points[0].x, .y = lane };
                points[2] = .{ .x = b.x + b.w / 2, .y = lane };
                points[3] = .{ .x = points[2].x, .y = b.y };
            } else {
                points[0] = .{ .x = a.x, .y = a.y + a.h / 2 };
                points[1] = .{ .x = lane, .y = points[0].y };
                points[2] = .{ .x = lane, .y = b.y + b.h / 2 };
                points[3] = .{ .x = b.x, .y = points[2].y };
            }
            label_at = points[1];
            if (edge.from == edge.to) {
                // Self loops need distinct entry/exit points.
                points[2].x += g.node_w * 0.35;
                points[3].x += g.node_w * 0.35;
            }
        }
        _ = &count;
        for (1..count) |k| line(ctx, clip, shifted(points[k - 1], origin), shifted(points[k], origin), color, edge.dotted);
        if (edge.arrow) {
            const tip = shifted(points[count - 1], origin);
            const prev = shifted(points[count - 2], origin);
            const dx: f32 = std.math.sign(tip.x - prev.x);
            const dy: f32 = std.math.sign(tip.y - prev.y);
            line(ctx, clip, tip, .{ .x = tip.x - dx * 7 + dy * 4, .y = tip.y - dy * 7 + dx * 4 }, color, false);
            line(ctx, clip, tip, .{ .x = tip.x - dx * 7 - dy * 4, .y = tip.y - dy * 7 - dx * 4 }, color, false);
        }
        if (edge.label.len > 0 and origin.y + label_at.y >= -g.size * 2 and origin.y + label_at.y <= clip.h + g.size * 2 and origin.x + label_at.x >= -g.gap and origin.x + label_at.x <= clip.w + g.gap) {
            const style: ui.TextStyle = .{ .size = g.size * 0.85, .color = ctx.theme.muted };
            const width = ctx.text.layout(edge.label, style).width;
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = origin.x + label_at.x - width / 2, .y = origin.y + label_at.y - g.size * 0.5 }, .background = ctx.theme.background, .padding = .{ .left = 3, .right = 3 } });
            ui.text(ctx, edge.label, style);
            ui.end(ctx);
        }
    }
    for (graph.nodes) |node| {
        const rect = nodeRect(g, graph, node);
        const x = rect.x + origin.x;
        const y = rect.y + origin.y;
        if (x + rect.w < 0 or x > clip.w or y + rect.h < 0 or y > clip.h) continue;
        if (node.shape == .decision) {
            const points = [_]ui.Point{ .{ .x = x + rect.w / 2, .y = y }, .{ .x = x + rect.w, .y = y + rect.h / 2 }, .{ .x = x + rect.w / 2, .y = y + rect.h }, .{ .x = x, .y = y + rect.h / 2 } };
            for (points, 0..) |point, i| line(ctx, clip, point, points[(i + 1) % 4], ctx.theme.accent, false);
        } else _ = ctx.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .radius = if (node.shape == .rounded) 16 else 5, .border = ctx.theme.accent.alpha(0.6), .background = ctx.theme.background.mix(ctx.theme.accent, 0.08) }, .none, null);
        const wrap_width = labelWidth(g, node);
        const rows = ctx.text.wrap(node.label, .{ .size = g.size }, wrap_width);
        for (rows, 0..) |row, i| {
            const end = if (i + 1 < rows.len) rows[i + 1].start else node.label.len;
            const label = std.mem.trim(u8, node.label[row.start..end], " ");
            const width = ctx.text.layout(label, .{ .size = g.size }).width;
            ui.column(ctx, .{ .absolute = true, .offset = .{ .x = x + (rect.w - width) / 2, .y = y + (rect.h - @as(f32, @floatFromInt(rows.len)) * g.size * 1.5) / 2 + @as(f32, @floatFromInt(i)) * g.size * 1.5 } });
            ui.text(ctx, label, .{ .size = g.size });
            ui.end(ctx);
        }
    }
}

pub fn sourceOffset(graph: *const flow.Graph, value: []const u8) usize {
    return @intFromPtr(value.ptr) - @intFromPtr(graph.source.ptr);
}
pub fn pointAt(ctx: *ui.Context, graph: *const flow.Graph, g: Geometry, byte: usize) ui.Rect {
    for (graph.nodes) |node| {
        const start = sourceOffset(graph, node.label);
        if (byte < start or byte > start + node.label.len) continue;
        const rect = nodeRect(g, graph, node);
        const rows = ctx.text.wrap(node.label, .{ .size = g.size }, labelWidth(g, node));
        for (rows, 0..) |row, i| {
            const end = if (i + 1 < rows.len) rows[i + 1].start else node.label.len;
            if (byte - start >= end and i + 1 < rows.len) continue;
            const value = node.label[row.start..end];
            const layout = ctx.text.layout(value, .{ .size = g.size });
            var x: f32 = if (byte - start >= end) layout.width else 0;
            var previous: usize = 0;
            for (layout.glyphs) |glyph| if (glyph.index <= byte - start - row.start and glyph.index >= previous) {
                x = glyph.x;
                previous = glyph.index;
            };
            return .{ .x = rect.x + (rect.w - layout.width) / 2 + x, .y = rect.y + (rect.h - @as(f32, @floatFromInt(rows.len)) * g.size * 1.5) / 2 + @as(f32, @floatFromInt(i)) * g.size * 1.5, .w = layout.width, .h = g.size * 1.5 };
        }
    }
    return .{ .x = if (byte >= graph.source.len) g.width else 0, .y = 0, .w = 1, .h = g.size * 1.5 };
}
pub fn hit(ctx: *ui.Context, graph: *const flow.Graph, g: Geometry, point: ui.Point) usize {
    for (graph.nodes) |node| {
        const rect = nodeRect(g, graph, node);
        if (!rect.contains(point)) continue;
        const rows = ctx.text.wrap(node.label, .{ .size = g.size }, labelWidth(g, node));
        const top = rect.y + (rect.h - @as(f32, @floatFromInt(rows.len)) * g.size * 1.5) / 2;
        const index: usize = @intFromFloat(std.math.clamp(@floor((point.y - top) / (g.size * 1.5)), 0, @as(f32, @floatFromInt(rows.len -| 1))));
        if (rows.len == 0) return sourceOffset(graph, node.label);
        const row = rows[index];
        const end = if (index + 1 < rows.len) rows[index + 1].start else node.label.len;
        const layout = ctx.text.layout(node.label[row.start..end], .{ .size = g.size });
        const x = point.x - rect.x - (rect.w - layout.width) / 2;
        var at = end - row.start;
        var distance = @abs(x - layout.width);
        for (layout.glyphs) |glyph| if (@abs(x - glyph.x) < distance) {
            distance = @abs(x - glyph.x);
            at = glyph.index;
        };
        return sourceOffset(graph, node.label) + row.start + at;
    }
    return if (point.x > g.width / 2) graph.source.len else 0;
}

fn labelWidth(g: Geometry, node: flow.Node) f32 {
    return if (node.shape == .decision) g.node_w * 0.5 else g.node_w - 28 * g.size / 14;
}
