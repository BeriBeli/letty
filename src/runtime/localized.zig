//! Translate product labels only; terminal output, paths and user text stay raw.
const ui = @import("nanoui").ui;
const locale = @import("locale.zig");
pub fn text(ctx: *ui.Context, label: []const u8, style: ui.TextStyle) void {
    ui.text(ctx, locale.t(label), style);
}
pub fn button(ctx: *ui.Context, label: []const u8, options: ui.ButtonOptions) ui.Interaction {
    return ui.button(ctx, locale.t(label), options);
}
pub fn field(ctx: *ui.Context, buffer: *ui.TextBuffer, options: ui.TextFieldOptions) ui.TextFieldResult {
    var opts = options;
    opts.placeholder = locale.t(opts.placeholder);
    return ui.textField(ctx, buffer, opts);
}
pub fn checkbox(ctx: *ui.Context, label: []const u8, value: *bool) bool {
    return ui.checkbox(ctx, locale.t(label), value);
}
