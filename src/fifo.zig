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

            var current_tail = self.tail.load(.SeqCst);

            var next_tail = (current_tail + items.len);

            var current_head = self.head.load(.SeqCst);
            if (current_head <= current_tail) {
                current_head += self.items.len;
            }

            if (next_tail >= current_head) {
                return error.FullQueue;
            }

            next_tail %= self.items.len;

            for (items, 0..) |item, i| {
                self.items[(current_tail + i) % self.items.len] = item;
            }

            self.tail.store(next_tail, .SeqCst);
        }

        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.Monotonic);
            if (current_head == self.tail.load(.Acquire))
                return null;

            const item = self.items[current_head];
            self.head.store(self.increment(current_head), .Release);
            return item;
        }

        // Returns a slice of `buffer` that will contains at most `buffer.len` items or less
        // if the buffer has not enough items loaded.
        pub fn popBuffer(self: *Self, buffer: []T) []T {
            const current_head = self.head.load(.Monotonic);

            var current_tail = self.tail.load(.Acquire);
            if (current_head == current_tail)
                return buffer[0..0];

            if (current_tail < current_head) {
                current_tail += self.items.len;
            }

            var items_to_pop = @min(buffer.len, current_tail - current_head);

            var sub_buffer = buffer[0..items_to_pop];

            for (sub_buffer, 0..) |*item, i| {
                item.* = self.items[(current_head + i) % self.items.len];
            }

            self.head.store((current_head + items_to_pop) % self.items.len, .Release);
            return sub_buffer;
        }

        // pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {}

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

    var buffer2 = [_]usize{0} ** 32;
    for (1..15) |i| {
        var slice = buffer2[0..i];
        for (slice, 0..) |*s, j| {
            s.* = j;
        }
        try fifo.pushBuffer(slice);

        for (0..i) |j| {
            try std.testing.expectEqual(@as(?usize, j), fifo.pop());
        }
    }

    try std.testing.expectEqual(@as(?usize, null), fifo.pop());

    var buffer3 = [_]usize{0} ** 32;
    for (1..18) |i| {
        var slice = buffer2[0..i];
        for (slice, 0..) |*s, j| {
            s.* = j;
        }

        var fail = false;
        fifo.pushBuffer(slice) catch {
            fail = true;
        };

        var slice3 = buffer3[0..i];
        var popped_buffer = fifo.popBuffer(slice3);
        if (fail) {
            try std.testing.expectEqual(@as([]usize, slice3[0..0]), popped_buffer);
        } else {
            try std.testing.expectEqualSlices(usize, slice, popped_buffer);
        }
    }
}

test "fifo buffer fuzz" {
    const size = 16;
    var buffer_fifo = [_]usize{0} ** size;
    var fifo = Fifo(usize).init(&buffer_fifo);

    var buffer = [_]usize{1} ** (size * 2);

    for (0..size) |tail| {
        for (0..size) |head| {
            for (0..size * 2) |subsize| {
                fifo.head.store(head, .SeqCst);
                fifo.tail.store(tail, .SeqCst);
                @memset(buffer_fifo[0..], 0);

                var expect = subsize;

                var startFifo = fifo;

                var subbuf = buffer[0..subsize];
                fifo.pushBuffer(subbuf) catch {
                    var len = @mod(@as(isize, @intCast(head)) - @as(isize, @intCast(tail)), size);
                    std.testing.expect(subsize >= (len - 1)) catch |e| {
                        std.log.err("Couldn't push {d} items but buffer had remaining size of {d} (fifo : {any})", .{ subsize, len, fifo });
                        return e;
                    };
                    expect = 0;
                };

                var sum: usize = 0;
                for (buffer_fifo) |item| {
                    sum += item;
                }

                std.testing.expectEqual(expect, sum) catch |e| {
                    std.log.err("Push {d} items but fifo has {d} items in it (fifo : {any})", .{ expect, sum, fifo });
                    return e;
                };

                var prevFifo = fifo;
                var sum_pop: usize = 0;
                while (fifo.pop()) |item| {
                    sum_pop += item;
                }

                std.testing.expectEqual(expect, sum_pop) catch |e| {
                    std.log.err("Push {d} items but could only pop {d} items in it.\n(start: {any})\n(prev : {any})\n(curr : {any})", .{ expect, sum_pop, startFifo, prevFifo, fifo });
                    return e;
                };
            }
        }
    }
}

test "fifo singlethread" {
    const size = 16;
    var buffer_fifo = [_]?i32{0} ** size;

    var ctx = TestCtx{
        .fifo = Fifo(?i32).init(&buffer_fifo),
        .producerResult = 0,
        .consumerResult = 0,
        .count = 1_000_000,
    };

    var prng = std.rand.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    var buffer: [size - 1]?i32 = undefined;

    var count = ctx.count;
    mainLoop: while (true) {
        if (count > 0) {
            var len = count % (size - 1);
            var subbuf = buffer[0..len];
            for (subbuf) |*s| {
                var number: i32 = random.int(u8);
                s.* = number;
            }

            var is_err = false;
            ctx.fifo.pushBuffer(subbuf) catch {
                is_err = true;
            };

            if (!is_err) {
                for (subbuf) |s| {
                    ctx.producerResult += s.?;
                }
                count -= 1;
            }
        } else {
            ctx.fifo.push(null) catch {};
        }

        var random_pop = random.intRangeAtMost(usize, 0, 32);
        for (0..random_pop) |_| {
            if (ctx.fifo.pop()) |item| {
                if (item) |i| {
                    ctx.consumerResult += i;
                } else {
                    break :mainLoop;
                }
            } else {
                break;
            }
        }
    }

    try std.testing.expectEqual(ctx.producerResult, ctx.consumerResult);
}

const test_base_buffer_len = 128;

test "fifo multithread" {
    const builtin = @import("builtin");
    try std.testing.expect(!builtin.single_threaded);

    const producersFn = [_][]const u8{ "testStartProducer", "testStartProducerBuffer" };
    const consumersFn = [_][]const u8{ "testStartConsumer", "testStartConsumerBuffer" };

    inline for (producersFn) |prod_fn_name| {
        inline for (consumersFn) |cons_fn_name| {
            const prod_fn = @field(@This(), prod_fn_name);
            const cons_fn = @field(@This(), cons_fn_name);

            testMultithread(prod_fn, cons_fn) catch |e| {
                std.log.err("Multithread fail with producer {s} and consumer {s}", .{ prod_fn_name, cons_fn_name });
                return e;
            };
        }
    }
}

fn testMultithread(comptime prodFn: anytype, comptime consFn: anytype) !void {
    // We push ctx.count random items from the producer buffer to the consumer buffer,
    // keeping a sum of all the items on both ends. When the producer thread has finished,
    // it pushes a null item, signalign to the consumer buffer to stop the count and return.
    // If the sums are equals at the end, we are good.

    var buffer = [_]?i32{0} ** test_base_buffer_len;

    var ctx = TestCtx{
        .fifo = Fifo(?i32).init(&buffer),
        .producerResult = 0,
        .consumerResult = 0,
        .count = 100_000,
    };

    var producer = try std.Thread.spawn(.{}, prodFn, .{&ctx});
    var consumer = try std.Thread.spawn(.{}, consFn, .{&ctx});

    producer.join();
    consumer.join();

    try std.testing.expectEqual(ctx.producerResult, ctx.consumerResult);
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
            var number: i32 = random.int(u31);
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

fn testStartConsumerBuffer(ctx: *TestCtx) void {
    var buffer: [test_base_buffer_len]?i32 = undefined;
    var slice = buffer[0..];

    loop: while (true) {
        std.time.sleep(1); // fuzz timings using the scheduler

        var items = ctx.fifo.popBuffer(slice);

        for (items) |item| {
            if (item) |i| {
                ctx.consumerResult += i;
            } else {
                // Stop the count when null is found
                break :loop;
            }
        }
    }
}
