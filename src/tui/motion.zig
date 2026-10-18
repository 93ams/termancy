//! Physics for animation, as harmonica does it: a damped spring that eases a value toward
//! a target (a progress bar filling, a panel sliding in), and a projectile under gravity.
//! Step them once per frame from a `Cmd.tick`.
//!
//! ```zig
//! var spring: tui.motion.Spring = .init(60, 6, 0.5); // 60 fps, frequency 6, damping 0.5
//! var position: f64 = 0;
//! var velocity: f64 = 0;
//! // each frame:
//! spring.update(&position, &velocity, target);
//! ```
//!
//! The spring is Ryan Juckett's closed-form damped harmonic oscillator, so it is stable
//! at any frame rate: under-damped (`damping` < 1) overshoots and settles, critically
//! damped (1) arrives fastest without overshoot, over-damped (> 1) arrives slowly.

const std = @import("std");

/// A damped spring, precomputed for one time step.
pub const Spring = struct {
    pos_pos: f64,
    pos_vel: f64,
    vel_pos: f64,
    vel_vel: f64,

    /// A spring stepped `fps` times a second, with `frequency` (angular, in radians a
    /// second: higher is faster) and `damping` (1 is critical).
    pub fn init(fps: f64, frequency: f64, damping: f64) Spring {
        return .initStep(1 / fps, frequency, damping);
    }

    /// A spring stepped every `dt` seconds.
    pub fn initStep(dt: f64, frequency_in: f64, damping_in: f64) Spring {
        const frequency = @max(frequency_in, 0);
        const damping = @max(damping_in, 0);
        const epsilon = 0.0001;
        if (frequency < epsilon) {
            return .{ .pos_pos = 1, .pos_vel = 0, .vel_pos = 0, .vel_vel = 1 };
        }
        if (damping > 1 + epsilon) {
            // Over-damped.
            const za = -frequency * damping;
            const zb = frequency * @sqrt(damping * damping - 1);
            const z1 = za - zb;
            const z2 = za + zb;
            const e1 = @exp(z1 * dt);
            const e2 = @exp(z2 * dt);
            const inv = 1 / (2 * zb);
            const e1_over = e1 * inv;
            const e2_over = e2 * inv;
            const z1e1 = z1 * e1_over;
            const z2e2 = z2 * e2_over;
            return .{
                .pos_pos = e1_over * z2 - z2e2 + e2,
                .pos_vel = -e1_over + e2_over,
                .vel_pos = (z1e1 - z2e2 + e2) * z2,
                .vel_vel = -z1e1 + z2e2,
            };
        }
        if (damping < 1 - epsilon) {
            // Under-damped.
            const omega_zeta = frequency * damping;
            const alpha = frequency * @sqrt(1 - damping * damping);
            const exp_term = @exp(-omega_zeta * dt);
            const cos_term = @cos(alpha * dt);
            const sin_term = @sin(alpha * dt);
            const inv_alpha = 1 / alpha;
            const exp_sin = exp_term * sin_term;
            const exp_cos = exp_term * cos_term;
            const exp_omega_zeta_sin_over_alpha = exp_term * omega_zeta * sin_term * inv_alpha;
            return .{
                .pos_pos = exp_cos + exp_omega_zeta_sin_over_alpha,
                .pos_vel = exp_sin * inv_alpha,
                .vel_pos = -exp_sin * alpha - omega_zeta * exp_omega_zeta_sin_over_alpha,
                .vel_vel = exp_cos - exp_omega_zeta_sin_over_alpha,
            };
        }
        // Critically damped.
        const exp_term = @exp(-frequency * dt);
        const time_exp = dt * exp_term;
        const time_exp_freq = time_exp * frequency;
        return .{
            .pos_pos = time_exp_freq + exp_term,
            .pos_vel = time_exp,
            .vel_pos = -frequency * time_exp_freq,
            .vel_vel = -time_exp_freq + exp_term,
        };
    }

    /// Moves `position` and `velocity` one step toward `target`.
    pub fn update(s: Spring, position: *f64, velocity: *f64, target: f64) void {
        const old = position.* - target;
        const old_velocity = velocity.*;
        position.* = old * s.pos_pos + old_velocity * s.pos_vel + target;
        velocity.* = old * s.vel_pos + old_velocity * s.vel_vel;
    }
};

/// A point in two or three dimensions.
pub const Point = struct { x: f64 = 0, y: f64 = 0, z: f64 = 0 };

/// Earth's gravity, pointing down the screen (y grows downward).
pub const gravity: Point = .{ .y = 9.81 };

/// A body thrown with a velocity and pulled by an acceleration, stepped every `dt`.
pub const Projectile = struct {
    position: Point,
    velocity: Point,
    acceleration: Point,
    dt: f64,

    /// A projectile stepped `fps` times a second.
    pub fn init(fps: f64, position: Point, velocity: Point, acceleration: Point) Projectile {
        return .{
            .position = position,
            .velocity = velocity,
            .acceleration = acceleration,
            .dt = 1 / fps,
        };
    }

    /// One step: the new position.
    pub fn update(p: *Projectile) Point {
        p.position.x += p.velocity.x * p.dt;
        p.position.y += p.velocity.y * p.dt;
        p.position.z += p.velocity.z * p.dt;
        p.velocity.x += p.acceleration.x * p.dt;
        p.velocity.y += p.acceleration.y * p.dt;
        p.velocity.z += p.acceleration.z * p.dt;
        return p.position;
    }
};

const testing = std.testing;

test "every kind of spring reaches its target" {
    for ([_]f64{ 0.2, 1, 2.5 }) |damping| {
        const spring: Spring = .init(60, 6, damping);
        var position: f64 = 0;
        var velocity: f64 = 0;
        var overshot = false;
        for (0..600) |_| {
            spring.update(&position, &velocity, 100);
            if (position > 100.5) overshot = true;
        }
        try testing.expectApproxEqAbs(100, position, 0.01);
        // Only an under-damped spring goes past the target.
        try testing.expectEqual(damping < 1, overshot);
    }
}

test "a spring with no frequency stays put" {
    const spring: Spring = .init(60, 0, 1);
    var position: f64 = 3;
    var velocity: f64 = 0;
    spring.update(&position, &velocity, 10);
    try testing.expectEqual(3, position);
}

test "a projectile falls" {
    var p: Projectile = .init(10, .{}, .{ .x = 1 }, gravity);
    var last: Point = .{};
    for (0..10) |_| last = p.update();
    try testing.expectApproxEqAbs(1, last.x, 1e-9);
    try testing.expect(last.y > 3 and last.y < 5);
}
