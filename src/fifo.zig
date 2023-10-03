const std = @import("std");

const Atomic = std.atomic.Atomic;

// Single Producer / Single Consumer FIFO
// Adapted from this article https://www.codeproject.com/articles/43510/lock-free-single-producer-single-consumer-circular
// (note that memory_order_relaxed in cpp is .Monotonic in Zig/LLVM : https://www.llvm.org/docs/Atomics.html#monotonic)
pub fn Fifo(comptime T: type) type {
    return struct {
        items: []T,
        tail: Atomic(usize),
        head: Atomic(usize),

        fn init(buffer: []T) Self {
            return .{
                .items = buffer,
                .tail = Atomic(usize).init(0),
                .head = Atomic(usize).init(0),
            };
        }

        pub fn push(self: *Self, item: T) !void {
            var current_tail = self.tail.load(.Monotonic);
            var next_tail = self.increment(current_tail);

            if (next_tail == self.head.load(.Acquire)) {
                return error.FullQueue;
            }

            self.items[current_tail] = item;
            self.tail.store(next_tail, .Release);
        }

        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.Monotonic);
            if (current_head == self.tail.load(.Acquire))
                return null;

            const item = self.items[current_head];
            self.head.store(self.increment(current_head), .Release);
            return item;
        }

        pub fn wasEmpty(self: *Self) bool {
            return self.head.load(.Monotonic) == self.tail.load(.Monotonic);
        }

        pub fn wasFull(self: *Self) bool {
            const next_tail = self.increment(self.tail.load(.Monotonic));
            return next_tail == self.head.load(.Monotonic);
        }

        inline fn increment(self: *Self, value: usize) usize {
            return (value + 1) % self.items.len;
        }

        const Self = @This();
    };
}

// Test under there

test "fifo simple" {
    var buffer = [_]usize{0} ** 16;
    var fifo = Fifo(usize).init(&buffer);

    // Test that the initial queue is empty
    try std.testing.expectEqual(@as(?usize, null), fifo.pop());
    try std.testing.expect(fifo.wasEmpty());

    try fifo.push(1);
    try std.testing.expectEqual(@as(?usize, 1), fifo.pop());
    try std.testing.expectEqual(@as(?usize, null), fifo.pop());

    // Test pushing and poping more items than the max capacity
    for (0..32) |i| {
        try fifo.push(i);
        try std.testing.expectEqual(@as(?usize, i), fifo.pop());
    }

    try std.testing.expectEqual(@as(?usize, null), fifo.pop());

    // Test pushing into full queue
    for (0..15) |i| {
        try fifo.push(i);
    }
    try std.testing.expectError(error.FullQueue, fifo.push(42));
    try std.testing.expect(fifo.wasFull());

    // Test that we can recover all of the items from the full queue
    for (0..15) |i| {
        try std.testing.expectEqual(@as(?usize, i), fifo.pop());
    }

    try std.testing.expectEqual(@as(?usize, null), fifo.pop());
}

test "fifo multithread" {
    const builtin = @import("builtin");
    try std.testing.expect(!builtin.single_threaded);

    var buffer = [_]i32{0} ** 128;

    var ctx = TestCtx{
        .fifo = Fifo(i32).init(&buffer),
        .producerResult = 0,
        .consumerResult = 0,
        .count = 10000000,
    };

    var producer = try std.Thread.spawn(.{}, testStartProducer, .{&ctx});
    var consumer = try std.Thread.spawn(.{}, testStartConsumer, .{&ctx});

    producer.join();
    consumer.join();

    try std.testing.expectEqual(ctx.producerResult, ctx.consumerResult);
}

const TestCtx = struct {
    fifo: Fifo(i32),
    producerResult: i64,
    consumerResult: i64,
    count: i64,
};

fn testStartProducer(ctx: *TestCtx) void {
    var prng = std.rand.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    var count = ctx.count;
    while (count != 0) : (count -= 1) {
        var number = random.int(i32);
        while (true) {
            std.time.sleep(1); // fuzz timings using the scheduler

            // if the queue is full (push returns an error, try again later)
            ctx.fifo.push(number) catch continue;
            break;
        }

        ctx.producerResult += number;
    }
}

fn testStartConsumer(ctx: *TestCtx) void {
    var count = ctx.count;
    while (count != 0) : (count -= 1) {
        while (true) {
            std.time.sleep(1); // fuzz timings using the scheduler

            // Make sure we pop exactly ONE item
            if (ctx.fifo.pop()) |item| {
                ctx.consumerResult += item;
                break;
            }
        }
    }
}
