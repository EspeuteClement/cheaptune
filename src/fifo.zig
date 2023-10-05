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

        pub fn init(buffer: []T) Self {
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

        pub fn pushBuffer(self: *Self, items: []T) !void {
            if (items.len == 0)
                return;
            if (items.len >= self.items.len)
                return error.BufferTooBig;

            var current_tail = self.tail.load(.Monotonic);

            var next_tail = (current_tail + items.len);

            var current_head = self.head.load(.Acquire);
            if (current_head <= current_tail) {
                current_head += self.items.len;
            }

            if (next_tail > current_head) {
                return error.FullQueue;
            }

            next_tail %= self.items.len;

            for (items, 0..) |item, i| {
                self.items[(current_tail + i) % self.items.len] = item;
            }

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

    var buffer2 = [_]usize{0} ** 15;
    for (1..15) |i| {
        var slice = buffer2[0..i];
        for (slice, 0..) |*s, j| {
            s.* = j;
        }
        try fifo.pushBuffer(slice);

        for (0..i) |j| {
            std.testing.expectEqual(@as(?usize, j), fifo.pop()) catch @panic("AAAA");
        }
    }
}

const test_base_buffer_len = 128;

test "fifo multithread" {
    const builtin = @import("builtin");
    try std.testing.expect(!builtin.single_threaded);

    {
        var buffer = [_]?i32{0} ** test_base_buffer_len;

        var ctx = TestCtx{
            .fifo = Fifo(?i32).init(&buffer),
            .producerResult = 0,
            .consumerResult = 0,
            .count = 1000000,
        };

        var producer = try std.Thread.spawn(.{}, testStartProducer, .{&ctx});
        var consumer = try std.Thread.spawn(.{}, testStartConsumer, .{&ctx});

        producer.join();
        consumer.join();

        try std.testing.expectEqual(ctx.producerResult, ctx.consumerResult);
    }

    {
        var buffer = [_]?i32{0} ** test_base_buffer_len;

        var ctx = TestCtx{
            .fifo = Fifo(?i32).init(&buffer),
            .producerResult = 0,
            .consumerResult = 0,
            .count = 10000,
        };

        var producer = try std.Thread.spawn(.{}, testStartProducerBuffer, .{&ctx});
        var consumer = try std.Thread.spawn(.{}, testStartConsumer, .{&ctx});

        producer.join();
        consumer.join();

        try std.testing.expectEqual(ctx.producerResult, ctx.consumerResult);
    }
}

const TestCtx = struct {
    fifo: Fifo(?i32),
    producerResult: i64,
    consumerResult: i64,
    count: usize,
};

fn testStartProducer(ctx: *TestCtx) void {
    var prng = std.rand.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    var count = ctx.count;
    while (count != 0) : (count -= 1) {
        std.time.sleep(1); // fuzz timings using the scheduler

        // if the queue is full (push returns an error, try again later)
        var len = count % 300;
        for (0..len) |_| {
            var number = random.int(i32);
            ctx.fifo.push(number) catch break;
            ctx.producerResult += number;
        }
    }

    while (true) {
        ctx.fifo.push(null) catch continue;
        break;
    }
}

fn testStartConsumer(ctx: *TestCtx) void {
    loop: while (true) {
        std.time.sleep(1); // fuzz timings using the scheduler

        // Pop as much items as we can
        while (ctx.fifo.pop()) |item| {
            if (item) |i| {
                ctx.consumerResult += i;
            } else {
                // Stop the count when null is found
                break :loop;
            }
        }
    }
}

fn testStartProducerBuffer(ctx: *TestCtx) void {
    var prng = std.rand.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    // We can put a most the lenght of the main buffer - 1, so we will test all sizes
    var buffer: [test_base_buffer_len - 1]?i32 = undefined;
    var count = ctx.count;
    while (count != 0) : (count -= 1) {
        var len = count % (test_base_buffer_len - 1);
        var subbuf = buffer[0..len];
        for (subbuf) |*s| {
            var number = random.int(i32);
            s.* = number;
            ctx.producerResult += number;
        }

        var timeout: usize = 10000;
        while (timeout > 0) : (timeout -= 1) {
            std.time.sleep(10);

            ctx.fifo.pushBuffer(subbuf) catch |err| {
                switch (err) {
                    error.BufferTooBig => @panic("Buffer shouldn't be too big"),
                    error.FullQueue => continue, // try again later
                }
            };

            break;
        } else {
            // Fail the test if we can't fill the buffer for some reason
            @panic("Timeout too many attempts at filling the buffer");
        }
    }

    while (true) {
        ctx.fifo.push(null) catch continue;
        break;
    }
}
