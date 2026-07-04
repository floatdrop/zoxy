//! OpenSSL FFI seam (docs/DESIGN.md §6, Phase 3 foundation).
//!
//! Hand-written extern declarations — no @cImport, no header dependency; the
//! C ABI surface we use is small and explicit. Everything OpenSSL allocates
//! goes through the process-global memory hook installed here, backed by a
//! fixed heap reserved at startup: no allocation outside pre-reserved pools,
//! and heap exhaustion fails the OpenSSL operation (load-shedding, not OOM).
//!
//! Ordering constraint: `install_memory_hook` must be the first OpenSSL
//! interaction in the process — OpenSSL rejects the hook once it has
//! allocated anything (lazy library init counts).

const std = @import("std");
const assert = std.debug.assert;

pub const Heap = @import("heap.zig").Heap;

pub const BIO = opaque {};
pub const X509 = opaque {};
pub const EVP_PKEY = opaque {};

var global_heap: Heap = undefined;
var hook_installed: bool = false;

pub const InstallError = error{
    /// A second install: the hook is process-global and installs exactly once.
    AlreadyInstalled,
    /// OpenSSL already allocated (lazy init ran before us) and refused the hook.
    OpenSslRejectedHook,
};

/// Install the process-global OpenSSL memory hook, backed by `region`
/// (reserved by the caller at startup, before any worker exists).
pub fn install_memory_hook(region: []align(Heap.block_align) u8) InstallError!void {
    assert(region.len >= 4096); // too small to run even library init otherwise
    if (hook_installed) return error.AlreadyInstalled;

    global_heap = Heap.init(region);
    if (CRYPTO_set_mem_functions(hook_malloc, hook_realloc, hook_free) != 1) {
        return error.OpenSslRejectedHook;
    }
    hook_installed = true;
    assert(memory_hook_stats().allocation_count == 0);
}

pub fn memory_hook_installed() bool {
    return hook_installed;
}

/// A locked snapshot of the hook heap's counters, for gates and (later)
/// admin metrics. Live count is the FFI analogue of pool occupancy: it must
/// return to its baseline when TLS work drains.
pub const HeapStats = struct {
    live_count: u64,
    allocation_count: u64,
    rejection_count: u64,
    carved_bytes: usize,
};

pub fn memory_hook_stats() HeapStats {
    assert(hook_installed);
    global_heap.mutex.lock();
    defer global_heap.mutex.unlock();
    return .{
        .live_count = global_heap.live_count,
        .allocation_count = global_heap.allocation_count,
        .rejection_count = global_heap.rejection_count,
        .carved_bytes = global_heap.carved_bytes,
    };
}

fn hook_malloc(bytes: usize, file: [*c]const u8, line: c_int) callconv(.c) ?*anyopaque {
    _ = file;
    _ = line;
    assert(hook_installed); // OpenSSL can only know these functions post-install
    if (bytes == 0) return null; // C-semantics malloc(0)
    return @ptrCast(global_heap.alloc(bytes));
}

fn hook_realloc(
    pointer: ?*anyopaque,
    bytes: usize,
    file: [*c]const u8,
    line: c_int,
) callconv(.c) ?*anyopaque {
    assert(hook_installed);
    const live = pointer orelse return hook_malloc(bytes, file, line);
    if (bytes == 0) {
        global_heap.free(@ptrCast(live));
        return null;
    }
    return @ptrCast(global_heap.realloc(@ptrCast(live), bytes));
}

fn hook_free(pointer: ?*anyopaque, file: [*c]const u8, line: c_int) callconv(.c) void {
    _ = file;
    _ = line;
    assert(hook_installed);
    const live = pointer orelse return; // C-semantics free(NULL)
    global_heap.free(@ptrCast(live));
}

pub const IdentityError = error{
    /// The certificate bytes do not parse as a PEM X.509 certificate.
    InvalidCertificate,
    /// The key bytes do not parse as a PEM private key.
    InvalidPrivateKey,
    /// Both parse, but the private key does not match the certificate.
    CertificateKeyMismatch,
};

/// Parse and cross-check a PEM certificate + private key. Startup-time only:
/// every allocation goes through the hook heap and is freed before return —
/// the long-lived SSL_CTX is built from these same bytes in the next slice.
pub fn validate_identity(
    certificate_pem: []const u8,
    private_key_pem: []const u8,
) IdentityError!void {
    assert(hook_installed); // install_memory_hook is the first OpenSSL call
    assert(certificate_pem.len > 0);
    assert(private_key_pem.len > 0);
    defer ERR_clear_error(); // never leak thread error-queue state to callers

    const certificate = read_pem_x509(certificate_pem) orelse
        return error.InvalidCertificate;
    defer X509_free(certificate);

    const private_key = read_pem_private_key(private_key_pem) orelse
        return error.InvalidPrivateKey;
    defer EVP_PKEY_free(private_key);

    if (X509_check_private_key(certificate, private_key) != 1) {
        return error.CertificateKeyMismatch;
    }
}

fn read_pem_x509(pem: []const u8) ?*X509 {
    assert(pem.len > 0);
    assert(pem.len <= std.math.maxInt(c_int)); // config parsing bounds file sizes
    const bio = BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse return null;
    defer _ = BIO_free(bio);
    return PEM_read_bio_X509(bio, null, null, null);
}

fn read_pem_private_key(pem: []const u8) ?*EVP_PKEY {
    assert(pem.len > 0);
    assert(pem.len <= std.math.maxInt(c_int));
    const bio = BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse return null;
    defer _ = BIO_free(bio);
    return PEM_read_bio_PrivateKey(bio, null, null, null);
}

pub extern fn OpenSSL_version_num() c_ulong;

extern fn CRYPTO_set_mem_functions(
    malloc_function: *const fn (usize, [*c]const u8, c_int) callconv(.c) ?*anyopaque,
    realloc_function: *const fn (?*anyopaque, usize, [*c]const u8, c_int) callconv(.c) ?*anyopaque,
    free_function: *const fn (?*anyopaque, [*c]const u8, c_int) callconv(.c) void,
) c_int;

extern fn BIO_new_mem_buf(buffer: *const anyopaque, length: c_int) ?*BIO;
extern fn BIO_free(bio: *BIO) c_int;
extern fn PEM_read_bio_X509(
    bio: *BIO,
    out: ?*?*X509,
    password_callback: ?*const anyopaque,
    callback_data: ?*anyopaque,
) ?*X509;
extern fn PEM_read_bio_PrivateKey(
    bio: *BIO,
    out: ?*?*EVP_PKEY,
    password_callback: ?*const anyopaque,
    callback_data: ?*anyopaque,
) ?*EVP_PKEY;
extern fn X509_free(certificate: *X509) void;
extern fn EVP_PKEY_free(key: *EVP_PKEY) void;
extern fn X509_check_private_key(certificate: *const X509, key: *const EVP_PKEY) c_int;
extern fn ERR_clear_error() void;

// -- tests --------------------------------------------------------------

const test_certificate_pem = @embedFile("testdata/certificate.pem");
const test_private_key_pem = @embedFile("testdata/private_key.pem");
const test_other_key_pem = @embedFile("testdata/other_key.pem");

/// The hook installs once per process, so every test funnels through this
/// shared region (sized for OpenSSL's lazy library init plus PEM work).
var test_heap_region: [4 * 1024 * 1024]u8 align(Heap.block_align) = undefined;

fn install_test_hook() !void {
    install_memory_hook(&test_heap_region) catch |err| switch (err) {
        error.AlreadyInstalled => {}, // another test got here first
        error.OpenSslRejectedHook => return err,
    };
    try std.testing.expect(memory_hook_installed());
}

test "openssl: linked, version is 3.x" {
    const version = OpenSSL_version_num();
    try std.testing.expect(version >= 0x3000_0000);
    try std.testing.expect(version < 0x4000_0000);
}

test "openssl: memory hook installs once, second install is rejected" {
    try install_test_hook();
    try std.testing.expectError(
        error.AlreadyInstalled,
        install_memory_hook(&test_heap_region),
    );
}

test "openssl: identity validation allocates only inside the hook heap and drains" {
    try install_test_hook();

    // Warm-up: OpenSSL's lazy init allocates long-lived globals on first use.
    try validate_identity(test_certificate_pem, test_private_key_pem);

    // Steady state: a validation must drain every allocation it makes.
    const before = memory_hook_stats();
    try validate_identity(test_certificate_pem, test_private_key_pem);
    const after = memory_hook_stats();
    try std.testing.expect(after.allocation_count > before.allocation_count); // FFI used the heap
    try std.testing.expectEqual(before.live_count, after.live_count); // and gave it all back
    try std.testing.expectEqual(@as(u64, 0), after.rejection_count);
}

test "openssl: corrupt certificate, corrupt key, and mismatched key are rejected" {
    try install_test_hook();

    try std.testing.expectError(
        error.InvalidCertificate,
        validate_identity("not a pem", test_private_key_pem),
    );
    try std.testing.expectError(
        error.InvalidPrivateKey,
        validate_identity(test_certificate_pem, "not a pem"),
    );
    try std.testing.expectError(
        error.CertificateKeyMismatch,
        validate_identity(test_certificate_pem, test_other_key_pem),
    );

    // Error paths must drain too — leaks here would bleed the heap on every
    // malformed handshake artifact.
    const before = memory_hook_stats();
    _ = validate_identity("not a pem", test_private_key_pem) catch {};
    const after = memory_hook_stats();
    try std.testing.expectEqual(before.live_count, after.live_count);
}
