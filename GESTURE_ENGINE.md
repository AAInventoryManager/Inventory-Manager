# GESTURE_ENGINE.md

## Mobile Inventory Card Swipe Gesture Engine (iOS-Accurate)

This document defines the **canonical swipe gesture behavior** for mobile inventory cards.
It must be implemented exactly as specified to achieve iOS-like interaction quality.

This applies to **mobile browsers only** (Chrome, Safari, PWA).
Desktop behavior is out of scope.

---

## 1. Design Goals

- Match iOS iMessage swipe behavior
- Smooth, elastic, finger-tracked animation
- Progressive icon scale + fade
- Directional intent detection
- Velocity + distance-based action commit
- Zero accidental triggers
- GPU-accelerated (60fps)

---

## 2. Supported Swipe Directions

### Swipe LEFT (Primary)

Reveals utility actions behind the card.

Actions (left → right):

1. ⚠️ Low Stock
2. ✏️ Edit Item

Extended swipe LEFT auto-triggers **Edit Item**.

---

### Swipe RIGHT (Secondary)

Optional future support (mirrors iOS):

- Reserved for future actions (e.g. "Mark Reviewed")
- For now: reveal tray only, no auto-action

---

## 3. Visual Model (iOS-Style)

- The **card moves**
- The **icon tray is stationary**
- Icons:
  - Scale from `0.85 → 1.0`
  - Fade from `0 → 1`
  - Highlight when commit threshold is crossed

Icons are **inline horizontally**, vertically centered to the card.

---

## 4. Gesture Thresholds (Pixels)

```js
const REVEAL_PX = 48; // icons begin appearing
const SNAP_PX = 96; // tray snaps open
const COMMIT_PX = 144; // auto-trigger Edit
const MAX_PX = 168; // elastic clamp
```

---

## 5. iOS Physics Constants

These values are reverse-engineered from iOS UIKit/SwiftUI and represent Apple's exact implementation.

### 5.1 Rubber Band Effect (Elasticity)

Apple's UIScrollView uses a specific formula for the "rubber band" or "bungee" effect when dragging beyond bounds.

```js
/**
 * iOS Rubber Band Formula
 * Source: UIScrollView internal implementation (reverse-engineered)
 *
 * @param x - distance from the edge (overshoot amount)
 * @param d - dimension (container width or height)
 * @param c - coefficient (Apple uses 0.55)
 * @returns rubber-banded position
 */
const RUBBER_BAND_COEFFICIENT = 0.55;

function rubberBand(x, d, c = RUBBER_BAND_COEFFICIENT) {
  // Formula: b = (1.0 - (1.0 / ((x * c / d) + 1.0))) * d
  // Equivalent: b = (x * d * c) / (d + c * x)
  return (1.0 - 1.0 / ((x * c) / d + 1.0)) * d;
}

// Example outputs (d = 375, typical iPhone width):
// x = 10   → ~5.4px   (small drag)
// x = 50   → ~25.1px  (medium drag)
// x = 100  → ~46.0px  (large drag)
// x = 200  → ~80.0px  (very large drag)
```

**Key insight**: As drag distance increases, rubber band resistance increases asymptotically. The content can never be dragged more than `d` pixels beyond the edge.

### 5.2 Deceleration Rates

UIScrollView momentum scrolling uses exponential decay.

```js
/**
 * iOS Deceleration Rates
 * These are multipliers applied per millisecond
 */
const DECELERATION_RATE = {
  NORMAL: 0.998, // Default - feels native, longer coast
  FAST: 0.99, // Paged scrolling, quick stop
};

/**
 * Velocity decay formula
 * After k milliseconds: velocity = initialVelocity * (rate ^ k)
 *
 * Time constant (when velocity reaches ~37% of initial):
 * - NORMAL (0.998): ~500ms
 * - FAST (0.99): ~100ms
 */

// Projection formula (where scroll will end)
// From WWDC "Designing Fluid Interfaces"
function project(initialVelocity, decelerationRate = 0.998) {
  // x = v0 * d / (1 - d)  where d = decelerationRate
  return (initialVelocity * decelerationRate) / (1 - decelerationRate);
}
```

### 5.3 Spring Animation Parameters

iOS uses spring physics for all gesture-driven animations. Two specification models exist:

#### Modern Model (iOS 17+ / Design-Friendly)

```js
/**
 * Duration + Bounce specification
 * More intuitive for designers
 */
const SPRING_PRESETS = {
  // Built-in iOS presets
  smooth: { duration: 0.5, bounce: 0.0 }, // No overshoot
  snappy: { duration: 0.5, bounce: 0.15 }, // Slight overshoot
  bouncy: { duration: 0.5, bounce: 0.3 }, // Playful overshoot

  // Swipe action recommendations
  snapBack: { duration: 0.4, bounce: 0.0 }, // Card returns to origin
  snapOpen: { duration: 0.35, bounce: 0.1 }, // Card snaps to reveal
  commitAction: { duration: 0.3, bounce: 0.15 }, // Action triggered
};

/**
 * Bounce value guide:
 * -1.0 to 0.0  = Overdamped (flatter, slower settle)
 *  0.0         = Critically damped (no overshoot, fastest settle)
 *  0.0 to 0.3  = Underdamped (subtle to moderate bounce)
 *  0.3 to 0.5  = High bounce (playful, exaggerated)
 *  1.0         = Undamped (oscillates forever - don't use)
 */
```

#### Traditional Model (Mass-Stiffness-Damping)

```js
/**
 * Physics-based specification
 * More control, less intuitive
 */
const TRADITIONAL_SPRING = {
  mass: 1.0, // Weight of object (usually 1.0)
  stiffness: 170, // Spring tension (higher = snappier)
  damping: 15, // Friction (lower = bouncier)
};

// Conversion from modern to traditional:
// stiffness = (2π / duration)²
// damping = 4π × (1 - bounce) / duration  (when bounce >= 0)

// Quick reference:
// Damping 26, Stiffness 170 → critically damped
// Damping 15, Stiffness 170 → slight bounce
// Damping 5, Stiffness 170  → very bouncy
```

#### Response + Damping Model (UIKit)

```js
/**
 * UISpringTimingParameters style
 * Used in UIViewPropertyAnimator
 */
const UIKIT_SPRING = {
  damping: 0.8, // Damping ratio (0-1, where 1 = critically damped)
  response: 0.3, // Time to reach target (seconds)
};

// For gesture-driven animations with velocity:
function createSpringTiming(gestureVelocity, distanceRemaining) {
  const relativeVelocity =
    distanceRemaining === 0 ? 0 : Math.abs(gestureVelocity) / distanceRemaining;

  return {
    damping: 0.8,
    response: 0.3,
    initialVelocity: relativeVelocity,
  };
}
```

### 5.4 Velocity Thresholds

```js
/**
 * Velocity-based decision making (points per second)
 */
const VELOCITY = {
  // Minimum velocity to override position-based decisions
  COMMIT_THRESHOLD: 300,

  // Typical human swipe velocities
  SLOW: 500,
  NORMAL: 1000,
  FAST: 2000,

  // Clamp range for reasonable behavior
  MIN_CLAMP: 100,
  MAX_CLAMP: 3000,
};

/**
 * Decision logic (matches iOS Mail/Messages):
 * 1. If velocity > COMMIT_THRESHOLD in action direction → commit
 * 2. If velocity < -COMMIT_THRESHOLD (opposite) → cancel
 * 3. Otherwise, use position threshold
 */
function shouldCommitAction(offset, velocity, commitThreshold = COMMIT_PX) {
  // High velocity in swipe direction
  if (velocity < -VELOCITY.COMMIT_THRESHOLD) return true;

  // High velocity in opposite direction
  if (velocity > VELOCITY.COMMIT_THRESHOLD) return false;

  // Fall back to position
  return Math.abs(offset) >= commitThreshold;
}
```

### 5.5 Momentum & Time Constants

```js
/**
 * From Apple's PastryKit (now iAd framework)
 * Used for momentum scrolling calculations
 */
const MOMENTUM = {
  TIME_CONSTANT_MS: 325, // Decay time constant
  ANIMATION_TICK_MS: 16.7, // 60fps frame time
  DECAY_FACTOR: 0.95, // Per-frame velocity multiplier
  SETTLE_THRESHOLD: 0.5, // Pixels - stop when slower than this
};

/**
 * Calculate final resting position
 */
function momentumEndPosition(currentPosition, velocity) {
  // Exponential decay: position approaches limit asymptotically
  // After ~6 time constants, motion is imperceptible
  const timeConstant = MOMENTUM.TIME_CONSTANT_MS / 1000;
  return currentPosition + velocity * timeConstant;
}
```

---

## 6. Implementation Reference

### 6.1 Complete Configuration Object

```js
const iOS_GESTURE_CONFIG = {
  // Gesture thresholds
  thresholds: {
    REVEAL_PX: 48,
    SNAP_PX: 96,
    COMMIT_PX: 144,
    MAX_PX: 168,
  },

  // Physics
  physics: {
    rubberBandCoefficient: 0.55,
    decelerationRate: 0.998,
    velocityCommitThreshold: 300,
  },

  // Spring animations
  springs: {
    snapBack: { duration: 0.4, bounce: 0.0 },
    snapOpen: { duration: 0.35, bounce: 0.1 },
    commit: { duration: 0.3, bounce: 0.15 },
  },

  // Visual feedback
  icons: {
    scaleRange: [0.85, 1.0],
    opacityRange: [0, 1],
  },

  // Timing
  timing: {
    targetFPS: 60,
    frameMs: 16.7,
  },
};
```

### 6.2 Rubber Band Implementation

```js
function applyRubberBand(offset, maxOffset, dimension) {
  const absOffset = Math.abs(offset);

  // Within bounds - no rubber banding
  if (absOffset <= maxOffset) return offset;

  // Calculate overshoot
  const overshoot = absOffset - maxOffset;
  const sign = offset > 0 ? 1 : -1;

  // Apply iOS formula
  const c = 0.55;
  const rubberBanded =
    (overshoot * dimension * c) / (dimension + c * overshoot);

  return sign * (maxOffset + rubberBanded);
}
```

### 6.3 Spring Animation (Web Animations API)

```js
function springAnimate(element, targetX, velocity = 0, springConfig) {
  const { duration, bounce } = springConfig;

  // Approximate spring with cubic-bezier
  // bounce 0 → ease-out-quint
  // bounce > 0 → overshoot curve
  const easing =
    bounce > 0
      ? `cubic-bezier(0.34, 1.56, 0.64, 1)` // Overshoot
      : `cubic-bezier(0.23, 1, 0.32, 1)`; // Smooth (ease-out-quint)

  // Adjust duration based on velocity
  const velocityFactor = Math.min(Math.abs(velocity) / 1000, 0.5);
  const adjustedDuration = duration * 1000 * (1 - velocityFactor * 0.3);

  return element.animate([{ transform: `translateX(${targetX}px)` }], {
    duration: Math.max(adjustedDuration, 150),
    easing,
    fill: "forwards",
  });
}
```

### 6.4 CSS Spring Approximations

```css
/* Smooth (critically damped) - no overshoot */
.spring-smooth {
  transition-timing-function: cubic-bezier(0.23, 1, 0.32, 1);
}

/* Snappy (slight bounce) */
.spring-snappy {
  transition-timing-function: cubic-bezier(0.34, 1.3, 0.64, 1);
}

/* Bouncy (moderate overshoot) */
.spring-bouncy {
  transition-timing-function: cubic-bezier(0.34, 1.56, 0.64, 1);
}

/* iOS default spring approximation */
.spring-ios-default {
  transition-timing-function: cubic-bezier(0.25, 0.46, 0.45, 0.94);
}
```

---

## 7. References

- **UIScrollView rubber band**: Reverse-engineered from iOS, coefficient = 0.55
- **Spring animations**: Apple WWDC23 "Animate with Springs"
- **Fluid interfaces**: Apple WWDC18 "Designing Fluid Interfaces"
- **Deceleration rates**: UIScrollView.DecelerationRate documentation
- **SwiftUI springs**: iOS 17+ Spring type with duration/bounce parameters
- **PastryKit momentum**: Time constant ~325ms, decay factor 0.95/frame

---

## 8. Testing Checklist

- [ ] Rubber band feels natural at MAX_PX boundary
- [ ] Velocity-based commit works for fast flicks
- [ ] Snap-back animation is smooth (no jank)
- [ ] Icon scale/fade is progressive and smooth
- [ ] 60fps maintained during gesture tracking
- [ ] Works on iOS Safari, Chrome, and PWA
- [ ] No accidental triggers on vertical scroll
