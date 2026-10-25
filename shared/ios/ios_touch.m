// iOS: on-screen touch controls, a UIKit overlay over SDL's window, modelled
// on OpenJKDF2's iOS port. While a level is being played (iosJK_IsPlaying):
//   - a floating move stick under the left thumb (+forward/+back/
//     +moveleft/+moveright)
//   - drag anywhere else to look (fed in as mouse movement); dragging on
//     FIRE or ALT looks too, so a thumb that lands on one while aiming keeps
//     aiming
//   - bottom right: FIRE (+attack), ALT (+altattack), JUMP (+moveup),
//     CROUCH (+movedown), USE (+use), FORCE (+useforce, the selected power)
//   - top left: NEXT WPN (weapnext), FORCE WHEEL and ITEM (see below), STYLE
//     (saberAttackCycle: the saber's stance), VIEW (cg_thirdperson !), GYRO; top right: QUICK SAVE, QUICK LOAD and
//     MENU (Escape, which also skips an in-game cutscene)
//   - QUICK SAVE and QUICK LOAD only go off when held: a ring round the
//     button fills (IOSTOUCH_QUICK_HOLD seconds), and once it is full the
//     game saves or loads ("save quik*", "load quik": F12 and F9 on PC) --
//     once, with the finger still down. Lifting sooner, or sliding off,
//     does nothing; and one completed hold ends every other, so both
//     pressed together do only the one that fills first.
//   - FORCE WHEEL: a quick tap selects the next learned power (forcenext); a
//     slide out of it, or a hold, opens the force wheel. Every selectable
//     power has a fixed slice, learned or not (those are dimmed): the light
//     side down the left, the neutral powers across the top, the dark side
//     down the right (Jedi Outcast's seven, or Jedi Academy's twelve); the
//     gap at the bottom cancels. Slide toward a power, or onto it, and lift to
//     select it; lift in the middle, the gap or back where you started for no
//     change. After a hold the wheel stays open: tap a power, or anywhere
//     else to close it. The game tells the overlay which powers are learned
//     (cg_iosforce) and selects one with "forceselect".
//   - ITEM: a quick tap uses the selected item (invuse); a slide or a hold
//     opens the item wheel, the same way: the five usable items across the
//     top (binoculars, bacta, seeker, light amp goggles, sentry), dimmed when
//     not carried, with how many; lifting on one selects it and uses it
//     ("invselect", then invuse). The game tells it what's carried (cg_iosinv).
//   - ⚙︎ (after GYRO) opens a small settings panel: Look speed (dragging, a
//     multiplier) and Gyro speed (degrees of view per degree of phone), applied
//     as the sliders move and remembered between launches
//   - GYRO turns gyro aiming on or off (lit while on, remembered between
//     launches): turning the phone turns the view too, along with dragging.
//     It runs only while a level is being played.
// The buttons run the game's commands, not keys, so they don't depend on the
// key bindings. While a video plays, a tap anywhere skips it (Escape). In
// the menus the overlay shows no buttons; a touch puts the menu pointer under
// the finger and clicks there (press as it lands, let go as it lifts), and
// dragging moves the pointer (sliders). A pointer moved by dragging, as with
// a mouse, can't work: touching to drag would already click wherever the
// pointer was, and the pause menu closes at a click outside it.
// Written for manual reference counting or ARC (the overlay lives for the
// whole process).

#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#include <os/lock.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <math.h>
#include <stdio.h>

#include "ios_bridge.h"

// Look speed: mouse counts per point of finger travel
#define IOSTOUCH_LOOK_SCALE_X 2.5f
#define IOSTOUCH_LOOK_SCALE_Y 2.0f
// ...times the Look speed setting (the ⚙︎ panel; kept under this key)
#define IOSTOUCH_LOOK_SPEED_DEFAULT 1.5f
#define IOSTOUCH_LOOK_SPEED_KEY @"iosTouchLookSpeed"
// The move stick: where it can start (the left part of the screen), its
// radius and its knob's, and how far it has to be pushed to move
#define IOSTOUCH_STICK_ZONE 0.42f
#define IOSTOUCH_STICK_RADIUS 60.0f
#define IOSTOUCH_STICK_KNOB 24.0f
#define IOSTOUCH_STICK_DEADZONE 0.30f
// Buttons show at this opacity while untouched
#define IOSTOUCH_IDLE_ALPHA 0.6
#define IOSTOUCH_MAX_TOUCHES 10
// The "+command" key numbers the overlay uses, so its presses never mix with
// a real key's (the engine counts presses per key number)
#define IOSTOUCH_KEYNUM_BASE 1000
// Gyro aiming: the view turns IOSTOUCH_GYRO_SCALE degrees per degree the
// phone turns, whatever the mouse settings (iosJK_GetMouseDegrees; zooming
// still slows it, as it does the mouse). Turning slower than
// IOSTOUCH_GYRO_TIGHTEN degrees a second counts for less, so a hand's slight
// shake doesn't shake the view. Samples come IOSTOUCH_GYRO_HZ times a
// second; one after a gap longer than IOSTOUCH_GYRO_MAX_GAP seconds only
// starts the count. Whether it's on is kept under IOSTOUCH_GYRO_DEFAULTS_KEY.
#define IOSTOUCH_GYRO_SCALE 1.5 // the default; the ⚙︎ panel's Gyro speed (kept under this key)
#define IOSTOUCH_GYRO_SPEED_KEY @"iosTouchGyroSpeed"
#define IOSTOUCH_GYRO_TIGHTEN 3.0
#define IOSTOUCH_GYRO_HZ 100.0
#define IOSTOUCH_GYRO_MAX_GAP 0.1
#define IOSTOUCH_GYRO_DEFAULTS_KEY @"iosTouchGyro"
// QUICK SAVE and QUICK LOAD have to be held this long, so a stray touch can't
// save over the quick save or throw away progress
#define IOSTOUCH_QUICK_HOLD 0.3
// FORCE WHEEL: a slide this far opens the wheel (and points); held this long
// without sliding, it opens and stays open for tapping
#define IOSTOUCH_WHEEL_DEAD 14.0
#define IOSTOUCH_WHEEL_HOLD 0.35
#define IOSTOUCH_WHEEL_CANCEL ( -2 ) // "slice" of the gap at the bottom

// The wheel's slices, in the game's showPowers order (forceselect's index):
// the middle of each, degrees counter-clockwise from pointing right (90: up),
// each the map's sliceDeg wide, and its group's colour
#define IOSTOUCH_WHEEL_MAX 12
typedef struct { const char *name; float deg; unsigned char r, g, b; } iosTouchWheelSlice;
#ifdef JK2_MODE
// Jedi Outcast's seven (showPowers order: heal, speed, push, pull, mind trick, grip, lightning)
#define IOSTOUCH_FORCE_SLICE_DEG 32.0f
static const iosTouchWheelSlice iosTouch_aForceSlices[] = {
	{ "HEAL",       198.0f, 120, 200, 255 }, // light side, down the left
	{ "SPEED",      126.0f, 255, 214, 120 }, // neutral, across the top
	{ "PUSH",        90.0f, 255, 214, 120 },
	{ "PULL",        54.0f, 255, 214, 120 },
	{ "MIND\nTRICK", 162.0f, 120, 200, 255 },
	{ "GRIP",        18.0f, 255, 105,  90 }, // dark side, down the right
	{ "LIGHTNING",  -18.0f, 255, 105,  90 },
};
#else
// Jedi Academy's twelve, in its showPowers order (absorb, heal, protect, mind
// trick; speed, push, pull, sight; drain, lightning, rage, grip): the light
// side down the left, the neutral powers across the top, the dark side down
// the right, each group from the top
#define IOSTOUCH_FORCE_SLICE_DEG 22.0f
static const iosTouchWheelSlice iosTouch_aForceSlices[] = {
	{ "ABSORB",      217.0f, 120, 200, 255 },
	{ "HEAL",        151.0f, 120, 200, 255 },
	{ "PROTECT",     195.0f, 120, 200, 255 },
	{ "MIND\nTRICK", 173.0f, 120, 200, 255 },
	{ "SPEED",       123.0f, 255, 214, 120 },
	{ "PUSH",        101.0f, 255, 214, 120 },
	{ "PULL",         79.0f, 255, 214, 120 },
	{ "SIGHT",        57.0f, 255, 214, 120 },
	{ "DRAIN",       -15.0f, 255, 105,  90 },
	{ "LIGHT-\nNING",  7.0f, 255, 105,  90 },
	{ "RAGE",        -37.0f, 255, 105,  90 },
	{ "GRIP",         29.0f, 255, 105,  90 },
};
#endif
// The items, in the game's order (INV_ELECTROBINOCULARS..INV_SENTRY: invselect's index)
static const iosTouchWheelSlice iosTouch_aItemSlices[] = {
	{ "BINOCU-\nLARS", 162.0f, 140, 220, 160 },
	{ "BACTA",         126.0f, 140, 220, 160 },
	{ "SEEKER",         90.0f, 140, 220, 160 },
	{ "LIGHT\nAMP",     54.0f, 140, 220, 160 },
	{ "SENTRY",         18.0f, 140, 220, 160 },
};
// A wheel: its slices; how the game says what's there (a cvar, "<mask>
// <selected> <value per slice>", values being levels or counts); the command
// that selects a slice (by index); what else lifting on one does
typedef struct {
	const iosTouchWheelSlice *aSlices;
	int numSlices;
	float sliceDeg;          // each slice's width
	float gapDeg;            // between slices (the gap at the bottom is what's left)
	const char *infoCvar;
	const char *selectCmd;
	const char *afterSelect; // a command line, or NULL
	int bCounts;             // values are counts (else levels: stars)
	const char *title;       // in the middle when nothing is selected
	const char *notThere;    // a slice not available: "not learned yet"
	const char *liftHint;    // "lift to select"
	const char *emptyTitle, *emptyHint;
} iosTouchWheelMap;
#define IOSTOUCH_COUNT( a ) ( (int)( sizeof( a ) / sizeof( ( a )[0] ) ) )
static const iosTouchWheelMap iosTouch_forceWheel = {
	iosTouch_aForceSlices, IOSTOUCH_COUNT( iosTouch_aForceSlices ), IOSTOUCH_FORCE_SLICE_DEG, 4.0f, "cg_iosforce", "forceselect", NULL, 0,
	"FORCE", "not learned yet", "lift to select", "NO POWERS", "none learned yet"
};
static const iosTouchWheelMap iosTouch_itemWheel = {
	iosTouch_aItemSlices, IOSTOUCH_COUNT( iosTouch_aItemSlices ), 32.0f, 4.0f, "cg_iosinv", "invselect", "invuse\n", 1,
	"ITEMS", "not carried", "lift to use", "NO ITEMS", "none carried"
};

enum { KIND_HOLD, KIND_TAP, KIND_MENU, KIND_GYRO, KIND_QUICK, KIND_WHEEL, KIND_SETTINGS };

typedef struct {
	const char *label;
	int kind;
	const char *command; // KIND_HOLD: "+attack" (and -attack on release); KIND_TAP: a command line
	float radius;
	int bLookWhileHeld;
	float x, y;
} iosTouchButton;

enum {
	BTN_FIRE, BTN_ALT, BTN_JUMP, BTN_CROUCH, BTN_USE, BTN_FORCE,
	BTN_NEXTWPN, BTN_WHEEL, BTN_ITEM, BTN_STYLE, BTN_VIEW, BTN_GYRO, BTN_SETTINGS,
	BTN_QUICKSAVE, BTN_QUICKLOAD, BTN_MENU,
	BTN_COUNT
};
static iosTouchButton iosTouch_aButtons[BTN_COUNT] = {
	[BTN_FIRE]      = { "FIRE",        KIND_HOLD, "+attack",    42.0f, 1 },
	[BTN_ALT]       = { "ALT",         KIND_HOLD, "+altattack", 28.0f, 1 },
	[BTN_JUMP]      = { "JUMP",        KIND_HOLD, "+moveup",    31.0f, 0 },
	[BTN_CROUCH]    = { "CROUCH",      KIND_HOLD, "+movedown",  29.0f, 0 },
	[BTN_USE]       = { "USE",         KIND_HOLD, "+use",       29.0f, 0 },
	[BTN_FORCE]     = { "FORCE",       KIND_HOLD, "+useforce",  30.0f, 0 },
	[BTN_NEXTWPN]   = { "NEXT\nWPN",   KIND_TAP,  "weapnext\n", 22.0f, 0 },
	[BTN_WHEEL]     = { "FORCE\nWHEEL", KIND_WHEEL, "forcenext\n", 22.0f, 0 },
	[BTN_ITEM]      = { "ITEM",        KIND_WHEEL, "invuse\n",  22.0f, 0 },
	[BTN_STYLE]     = { "STYLE",       KIND_TAP,  "saberAttackCycle\n", 22.0f, 0 },
	[BTN_VIEW]      = { "VIEW",        KIND_TAP,  "cg_thirdperson !\n", 22.0f, 0 },
	[BTN_GYRO]      = { "GYRO",        KIND_GYRO, NULL,         22.0f, 0 },
	[BTN_SETTINGS]  = { "⚙︎",           KIND_SETTINGS, NULL,     22.0f, 0 },
	[BTN_QUICKSAVE] = { "QUICK\nSAVE", KIND_QUICK, "save quik*\n", 22.0f, 0 },
	[BTN_QUICKLOAD] = { "QUICK\nLOAD", KIND_QUICK, "load quik\n",  22.0f, 0 },
	[BTN_MENU]      = { "MENU",        KIND_MENU, NULL,         22.0f, 0 },
};

enum {
	ROLE_NONE, ROLE_STICK, ROLE_LOOK, ROLE_BUTTON, ROLE_MENU,
	ROLE_WHEELBTN, // on FORCE WHEEL, not yet a tap, a slide or a hold
	ROLE_WHEEL,    // a finger on the open wheel (bOpener: the one that opened it by sliding)
	ROLE_IGNORED,  // was down when the wheel opened or closed; ignored until it lifts
};

typedef struct {
	UITouch *touch; // not retained; only compared
	int role;
	int button;
	CGPoint origin;
	CGPoint last;
	CFTimeInterval tDown; // when it landed (CACurrentMediaTime)
	int bFired;           // KIND_QUICK: its hold is over (saved, loaded, slid off, or another hold went off)
	int bOpener;          // ROLE_WHEEL: opened the wheel by sliding; points by direction
	int wheelSlot;        // ROLE_WHEEL: the slice pointed at, IOSTOUCH_WHEEL_CANCEL, or -1
} iosTouchSlot;

// a - b, in degrees, as -180..180
static CGFloat iosTouch_AngleDiff( CGFloat a, CGFloat b )
{
	CGFloat d = fmod( a - b, 360.0 );
	if ( d > 180.0 ) d -= 360.0;
	if ( d < -180.0 ) d += 360.0;
	return d;
}

// The slice a direction (degrees) points into, or IOSTOUCH_WHEEL_CANCEL
static int iosTouch_WheelSliceForAngle( const iosTouchWheelMap *m, CGFloat deg )
{
	for ( int i = 0; i < m->numSlices; i++ ) {
		if ( fabs( iosTouch_AngleDiff( deg, m->aSlices[i].deg ) ) <= ( m->sliceDeg + m->gapDeg ) * 0.5 )
			return i;
	}
	return IOSTOUCH_WHEEL_CANCEL;
}

static iosTouchSlot iosTouch_aSlots[IOSTOUCH_MAX_TOUCHES];
static int iosTouch_aHeld[BTN_COUNT];  // touches holding each button
static float iosTouch_lookX, iosTouch_lookY;
// The move stick's directions being held: forward, back, left, right
static int iosTouch_aStickDown[4];
static const char *iosTouch_aStickCmd[4] = { "forward", "back", "moveleft", "moveright" };

static void iosTouch_SetHeld( const char *plusCommand, int keynum, int bDown )
{
	char line[64];
	snprintf( line, sizeof( line ), "%c%s %d\n", bDown ? '+' : '-', plusCommand + 1, keynum );
	iosJK_Command( line );
}

// The stick at (x, y), -1..1 each way: presses and releases the move commands
static void iosTouch_SetStick( float x, float y, int bActive )
{
	int aWant[4] = {
		bActive && y < -IOSTOUCH_STICK_DEADZONE,
		bActive && y > IOSTOUCH_STICK_DEADZONE,
		bActive && x < -IOSTOUCH_STICK_DEADZONE,
		bActive && x > IOSTOUCH_STICK_DEADZONE,
	};
	for ( int i = 0; i < 4; i++ ) {
		if ( aWant[i] == iosTouch_aStickDown[i] ) continue;
		iosTouch_aStickDown[i] = aWant[i];
		char line[64];
		snprintf( line, sizeof( line ), "%c%s %d\n", aWant[i] ? '+' : '-', iosTouch_aStickCmd[i], IOSTOUCH_KEYNUM_BASE + BTN_COUNT + i );
		iosJK_Command( line );
	}
}

// The ⚙︎ panel's settings
static float iosTouch_lookSpeed = IOSTOUCH_LOOK_SPEED_DEFAULT;
static float iosTouch_gyroSpeed = IOSTOUCH_GYRO_SCALE;

// ---------------------------------------------------------------- gyro aiming

// Whether it's on, and whether motion updates are coming in (only while on
// and playing). Updates arrive on iosTouch_pMotionQueue, which adds up how
// far the view should turn (degrees: right, up) until iosTouch_Update takes
// it; the lock guards that and iosTouch_gyroGen, which goes up at each start
// so a sample left over from an earlier run is dropped.
// iosTouch_gyroOrientation is the screen's (UIInterfaceOrientation), for
// turning the device's axes into the screen's.
static CMMotionManager *iosTouch_pMotion = nil;
static NSOperationQueue *iosTouch_pMotionQueue = nil;
static int iosTouch_bGyro = 0;
static int iosTouch_bGyroRunning = 0;
static os_unfair_lock iosTouch_gyroLock = OS_UNFAIR_LOCK_INIT;
static double iosTouch_gyroRightDeg = 0.0, iosTouch_gyroUpDeg = 0.0;
static int iosTouch_gyroGen = 0;
static volatile long iosTouch_gyroOrientation = UIInterfaceOrientationLandscapeRight;
// How the device's motion axes sit against the screen, in quarter turns
// (0: as on an iPhone, where the screen's portrait is the body's), or -1
// until gravity has said: some devices' screens are turned against their
// body, and a quarter turn off, sideways turns would read as tilts. Decided
// (on the samples' queue only) by which quarter turn has the screen's top
// pointing up for IOSTOUCH_GYRO_QUARTER_VOTES samples running, the phone
// held well off flat; decided again when the gyro starts or the screen turns
// round (iosTouch_gyroQuarterOrientation: the orientation it was decided for).
static int iosTouch_gyroQuarter = -1, iosTouch_gyroQuarterVote = -1, iosTouch_gyroQuarterVotes = 0;
static long iosTouch_gyroQuarterOrientation = -1;
#define IOSTOUCH_GYRO_QUARTER_VOTES 15

// A device-axes vector (x, y) as the screen's (right, up), for this orientation
static void iosTouch_GyroToScreen( long orientation, double x, double y, double *pRight, double *pUp )
{
	switch ( orientation ) {
		case UIInterfaceOrientationLandscapeRight: *pRight = -y; *pUp = x; break; // the phone's top on the left
		case UIInterfaceOrientationLandscapeLeft:  *pRight = y; *pUp = -x; break; // the phone's top on the right
		case UIInterfaceOrientationPortraitUpsideDown: *pRight = -x; *pUp = -y; break;
		default: *pRight = x; *pUp = y; break;
	}
}

// How far one motion sample turns the view, in degrees (right, up), dt
// seconds after the last. The device's axes become the screen's (x right, y
// up, z out of the screen). Up and down is the turn about the screen's x
// axis. Left and right is the turn about the real vertical, from gravity, so
// it means the same however far back the phone is tilted -- made up to 1.41
// times bigger, but never more than the turn about the screen's y and z axes
// together (JoyShockMapper's "player space").
static void iosTouch_GyroSample( CMDeviceMotion *m, double dt, double *pRight, double *pUp )
{
	CMRotationRate r = m.rotationRate;
	CMAcceleration g = m.gravity;
	const long orientation = iosTouch_gyroOrientation;
	double wx = r.x, wy = r.y, dgx = g.x, dgy = g.y;

	// How the device's axes sit against the screen: the quarter turn that has
	// the screen's top up (gravity pointing down the screen)
	double gl0 = sqrt( dgx * dgx + dgy * dgy + g.z * g.z );
	if ( orientation != iosTouch_gyroQuarterOrientation ) {
		iosTouch_gyroQuarter = iosTouch_gyroQuarterVote = -1;
		iosTouch_gyroQuarterVotes = 0;
		iosTouch_gyroQuarterOrientation = orientation;
	}
	if ( iosTouch_gyroQuarter < 0 && gl0 > 0.5 && sqrt( dgx * dgx + dgy * dgy ) / gl0 > 0.6 ) {
		int best = 0;
		double bestUp = -1e9, x = dgx, y = dgy;
		for ( int k = 0; k < 4; k++ ) {
			double right, up;
			iosTouch_GyroToScreen( orientation, x, y, &right, &up );
			if ( -up > bestUp ) { bestUp = -up; best = k; } // the screen's top up: gravity down it
			double t = x; x = -y; y = t; // the next quarter turn: (x, y) -> (-y, x)
		}
		iosTouch_gyroQuarterVotes = ( best == iosTouch_gyroQuarterVote ) ? iosTouch_gyroQuarterVotes + 1 : 1;
		iosTouch_gyroQuarterVote = best;
		if ( iosTouch_gyroQuarterVotes >= IOSTOUCH_GYRO_QUARTER_VOTES ) iosTouch_gyroQuarter = best;
	}
	for ( int k = 0; k < ( iosTouch_gyroQuarter > 0 ? iosTouch_gyroQuarter : 0 ); k++ ) {
		double t = wx; wx = -wy; wy = t;
		t = dgx; dgx = -dgy; dgy = t;
	}

	double rx, ry, gx, gy;
	iosTouch_GyroToScreen( orientation, wx, wy, &rx, &ry );
	iosTouch_GyroToScreen( orientation, dgx, dgy, &gx, &gy );
	double rz = r.z, gz = g.z;

	// radians a second; positive: turning left, and tipping the top edge
	// toward you (the back of the phone, the way the view looks, turns up)
	double left = ry;
	double up = rx;
	double gl = sqrt( gx * gx + gy * gy + gz * gz );
	if ( gl > 0.5 ) {
		double world = -( rx * gx + ry * gy + rz * gz ) / gl; // about "up", gravity pointing down
		left = copysign( fmin( fabs( world ) * 1.41, hypot( ry, rz ) ), world );
	}

	// Slow turns count for less
	double speed = hypot( left, up );
	double tighten = IOSTOUCH_GYRO_TIGHTEN * M_PI / 180.0;
	if ( speed < tighten ) {
		left *= speed / tighten;
		up *= speed / tighten;
	}

	*pRight = -left * dt * 180.0 / M_PI;
	*pUp = up * dt * 180.0 / M_PI;
}

static void iosTouch_StartGyro( void )
{
	if ( !iosTouch_pMotionQueue ) {
		iosTouch_pMotionQueue = [[NSOperationQueue alloc] init];
		iosTouch_pMotionQueue.maxConcurrentOperationCount = 1;
	}
	os_unfair_lock_lock( &iosTouch_gyroLock );
	int gen = ++iosTouch_gyroGen;
	iosTouch_gyroRightDeg = iosTouch_gyroUpDeg = 0.0;
	os_unfair_lock_unlock( &iosTouch_gyroLock );

	// only this queue's blocks touch lastT and the quarter turn, one at a
	// time; the quarter turn is decided again (the queue is idle here)
	__block NSTimeInterval lastT = 0.0;
	iosTouch_gyroQuarterOrientation = -1;
	iosTouch_pMotion.deviceMotionUpdateInterval = 1.0 / IOSTOUCH_GYRO_HZ;
	[iosTouch_pMotion startDeviceMotionUpdatesToQueue:iosTouch_pMotionQueue withHandler:^( CMDeviceMotion *m, NSError *err ) {
		if ( !m ) return;
		double dt = m.timestamp - lastT;
		int bFirst = lastT == 0.0;
		lastT = m.timestamp;
		if ( bFirst || dt <= 0.0 || dt > IOSTOUCH_GYRO_MAX_GAP ) return;
		double right, up;
		iosTouch_GyroSample( m, dt, &right, &up );
		os_unfair_lock_lock( &iosTouch_gyroLock );
		if ( gen == iosTouch_gyroGen ) {
			iosTouch_gyroRightDeg += right;
			iosTouch_gyroUpDeg += up;
		}
		os_unfair_lock_unlock( &iosTouch_gyroLock );
	}];
	iosTouch_bGyroRunning = 1;
}

static void iosTouch_StopGyro( void )
{
	[iosTouch_pMotion stopDeviceMotionUpdates];
	os_unfair_lock_lock( &iosTouch_gyroLock );
	iosTouch_gyroGen++; // anything still queued is dropped
	iosTouch_gyroRightDeg = iosTouch_gyroUpDeg = 0.0;
	os_unfair_lock_unlock( &iosTouch_gyroLock );
	iosTouch_bGyroRunning = 0;
}

// Once per frame: motion updates run only while gyro aiming is on and a level
// is being played, and how far the phone turned since last time goes in with
// the dragging, as mouse movement turning the view by that angle
static void iosTouch_UpdateGyro( int bPlaying, UIView *v )
{
	int bWant = bPlaying && iosTouch_bGyro && iosTouch_pMotion.deviceMotionAvailable;
	if ( bWant && !iosTouch_bGyroRunning ) iosTouch_StartGyro( );
	else if ( !bWant && iosTouch_bGyroRunning ) iosTouch_StopGyro( );
	if ( !iosTouch_bGyroRunning ) return;

	UIWindowScene *scene = v.window.windowScene;
	if ( scene ) iosTouch_gyroOrientation = scene.interfaceOrientation;

	os_unfair_lock_lock( &iosTouch_gyroLock );
	double right = iosTouch_gyroRightDeg, up = iosTouch_gyroUpDeg;
	iosTouch_gyroRightDeg = iosTouch_gyroUpDeg = 0.0;
	os_unfair_lock_unlock( &iosTouch_gyroLock );

	float yawDeg, pitchDeg;
	iosJK_GetMouseDegrees( &yawDeg, &pitchDeg );
	// mouse right turns right; mouse down looks down (m_pitch > 0), so up is
	// negative counts -- by the size of m_pitch, so an inverted mouse doesn't
	// invert the phone
	if ( fabsf( yawDeg ) > 1e-6f ) iosTouch_lookX += (float)( right * iosTouch_gyroSpeed / fabsf( yawDeg ) );
	if ( fabsf( pitchDeg ) > 1e-6f ) iosTouch_lookY -= (float)( up * iosTouch_gyroSpeed / pitchDeg );
}

// ---------------------------------------------------------------- overlay view

@interface IOSTouchOverlay : UIView {
	// The ⚙︎ panel
	UIView *settingsPanel;
	UISlider *lookSlider, *gyroSlider;
	UILabel *lookValue, *gyroValue;
	// The force wheel: open or not (and whether it stays open for tapping),
	// its views, where it is, what the game says is learned and selected
	int bWheelOpen;
	int bWheelTapMode;
	UIView *wheelView;
	const iosTouchWheelMap *pWheel; // which wheel is open
	CAShapeLayer *aSliceLayers[IOSTOUCH_WHEEL_MAX];
	UILabel *aSliceLabels[IOSTOUCH_WHEEL_MAX];
	UILabel *wheelTitle;
	UILabel *wheelHint;
	CGPoint wheelCentre;
	CGFloat wheelR0, wheelR1;
	int wheelLearned, wheelSelected, aWheelLevels[IOSTOUCH_WHEEL_MAX]; // learned / carried, selected, levels / counts
	int wheelLastHot;
	UISelectionFeedbackGenerator *wheelTick;
	CAShapeLayer *aQuickRings[BTN_COUNT]; // KIND_QUICK: fills while held
	int bMenuFingerDown;
	UILabel *aButtonViews[BTN_COUNT];
	UIView *stickBase;
	UIView *stickKnob;
	int bStickActive;
}
- (void)releaseAll;
- (void)showSettings:(BOOL)bShow;
- (void)tick;
- (void)viewWithGyroHidden;
- (void)refreshGyroLook;
@end

@implementation IOSTouchOverlay

static UIView *IOSTouch_MakeCircle( CGFloat r, CGFloat alpha )
{
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, r * 2, r * 2 )];
	v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:alpha];
	v.layer.cornerRadius = r;
	v.layer.borderWidth = 1.5;
	v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
	v.userInteractionEnabled = NO;
	return v;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if ( self ) {
		self.backgroundColor = [UIColor clearColor];
		self.multipleTouchEnabled = YES;
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		for ( int i = 0; i < BTN_COUNT; i++ ) {
			iosTouchButton *b = &iosTouch_aButtons[i];
			UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake( 0, 0, b->radius * 2, b->radius * 2 )];
			l.text = [NSString stringWithUTF8String:b->label];
			l.textAlignment = NSTextAlignmentCenter;
			l.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
			l.numberOfLines = 2;
			l.font = [UIFont boldSystemFontOfSize:( strchr( b->label, '\n' ) ? 9 : ( b->radius >= 40 ? 16 : ( b->radius >= 25 ? 12 : 10 ) ) )];
			l.adjustsFontSizeToFitWidth = YES;
			l.minimumScaleFactor = 0.6;
			l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
			l.layer.cornerRadius = b->radius;
			l.layer.borderWidth = 1.5;
			l.layer.borderColor = ( i == BTN_FIRE ) ? [UIColor colorWithRed:1.0 green:0.55 blue:0.45 alpha:0.7].CGColor
			                                        : [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
			l.clipsToBounds = YES;
			l.userInteractionEnabled = NO;
			l.alpha = IOSTOUCH_IDLE_ALPHA;
			aButtonViews[i] = l;
			[self addSubview:l];
		}
		// QUICK SAVE's and QUICK LOAD's rings
		for ( int i = 0; i < BTN_COUNT; i++ ) {
			if ( iosTouch_aButtons[i].kind != KIND_QUICK ) continue;
			CGFloat r = iosTouch_aButtons[i].radius;
			CAShapeLayer *ring = [CAShapeLayer layer];
			ring.frame = CGRectMake( 0, 0, r * 2, r * 2 );
			ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake( r, r ) radius:r - 2.5
			                                       startAngle:-M_PI_2 endAngle:3 * M_PI_2 clockwise:YES].CGPath;
			ring.fillColor = [UIColor clearColor].CGColor;
			ring.strokeColor = [UIColor colorWithRed:0.47 green:0.78 blue:1.0 alpha:0.95].CGColor;
			ring.lineWidth = 3.0;
			ring.strokeEnd = 0.0;
			[aButtonViews[i].layer addSublayer:ring];
			aQuickRings[i] = ring;
		}

		// GYRO, if there is a gyroscope to aim with
		if ( !iosTouch_pMotion ) iosTouch_pMotion = [[CMMotionManager alloc] init];
		aButtonViews[BTN_GYRO].hidden = !iosTouch_pMotion.deviceMotionAvailable;
		iosTouch_bGyro = iosTouch_pMotion.deviceMotionAvailable
		                 && [[NSUserDefaults standardUserDefaults] boolForKey:IOSTOUCH_GYRO_DEFAULTS_KEY];
		[self refreshGyroLook];

		stickBase = IOSTouch_MakeCircle( IOSTOUCH_STICK_RADIUS, 0.08 );
		stickKnob = IOSTouch_MakeCircle( IOSTOUCH_STICK_KNOB, 0.30 );
		stickBase.hidden = YES;
		stickKnob.hidden = YES;
		[self addSubview:stickBase];
		[self addSubview:stickKnob];

		// The force wheel, on top, hidden until opened: dims the game behind it
		wheelView = [[UIView alloc] initWithFrame:self.bounds];
		wheelView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		wheelView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
		wheelView.userInteractionEnabled = NO; // the overlay takes its touches
		wheelView.hidden = YES;
		for ( int i = 0; i < IOSTOUCH_WHEEL_MAX; i++ ) {
			aSliceLayers[i] = [CAShapeLayer layer];
			aSliceLayers[i].lineWidth = 2.0;
			[wheelView.layer addSublayer:aSliceLayers[i]];
			UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake( 0, 0, 80, 44 )];
			l.textAlignment = NSTextAlignmentCenter;
			l.numberOfLines = 3;
			l.font = [UIFont boldSystemFontOfSize:11];
			l.adjustsFontSizeToFitWidth = YES;
			l.minimumScaleFactor = 0.7;
			aSliceLabels[i] = l;
			[wheelView addSubview:l];
		}
		wheelTitle = [[UILabel alloc] initWithFrame:CGRectMake( 0, 0, 120, 24 )];
		wheelTitle.textAlignment = NSTextAlignmentCenter;
		wheelTitle.font = [UIFont boldSystemFontOfSize:16];
		wheelTitle.adjustsFontSizeToFitWidth = YES;
		wheelTitle.minimumScaleFactor = 0.6;
		[wheelView addSubview:wheelTitle];
		wheelHint = [[UILabel alloc] initWithFrame:CGRectMake( 0, 0, 120, 14 )];
		wheelHint.textAlignment = NSTextAlignmentCenter;
		wheelHint.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
		wheelHint.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
		wheelHint.adjustsFontSizeToFitWidth = YES;
		[wheelView addSubview:wheelHint];
		[self addSubview:wheelView];
		wheelLastHot = -1;
		wheelTick = [[UISelectionFeedbackGenerator alloc] init];

		// The ⚙︎ panel, and the settings it keeps
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		if ( [defaults objectForKey:IOSTOUCH_LOOK_SPEED_KEY] ) iosTouch_lookSpeed = [defaults floatForKey:IOSTOUCH_LOOK_SPEED_KEY];
		if ( [defaults objectForKey:IOSTOUCH_GYRO_SPEED_KEY] ) iosTouch_gyroSpeed = [defaults floatForKey:IOSTOUCH_GYRO_SPEED_KEY];
		[self makeSettingsPanel];
	}
	return self;
}

// Bottom right, under the right thumb, clear of the HUD's right gauge (the
// bottom right corner of the game's 640x480 screen, x 560-640, y 400-480):
// FIRE just left of it, CROUCH / USE / JUMP on an arc round FIRE (left, up
// left, up), ALT above the gauge, FORCE up and left of JUMP, over USE.
// Top left: NEXT WPN, NEXT FORCE, ITEM, VIEW, GYRO; top right: MENU. All
// inside the safe area (the cutout, the home bar).
- (void)layoutSubviews
{
	[super layoutSubviews];
	CGSize sz = self.bounds.size;
	UIEdgeInsets in = self.safeAreaInsets;
	CGFloat left = MAX( in.left, 8.0 ), right = sz.width - MAX( in.right, 8.0 );
	CGFloat top = MAX( in.top, 8.0 ), bottom = sz.height - MAX( in.bottom, 8.0 );

	const CGFloat gaugeLeft = sz.width * 560.0 / 640.0;  // the HUD's right gauge
	const CGFloat gaugeTop = sz.height * 400.0 / 480.0;
	const CGFloat FR = iosTouch_aButtons[BTN_FIRE].radius;
	CGPoint fire = CGPointMake( MIN( gaugeLeft - FR - 8, right - FR ), bottom - FR - 10 );
	iosTouch_aButtons[BTN_FIRE].x = fire.x;
	iosTouch_aButtons[BTN_FIRE].y = fire.y;
	const CGFloat arc = 108.0;
	const int aArc[3] = { BTN_CROUCH, BTN_USE, BTN_JUMP };
	const CGFloat aDeg[3] = { 180.0, 135.0, 90.0 };
	for ( int i = 0; i < 3; i++ ) {
		CGFloat rad = aDeg[i] * M_PI / 180.0;
		iosTouch_aButtons[aArc[i]].x = fire.x + arc * cos( rad );
		iosTouch_aButtons[aArc[i]].y = fire.y - arc * sin( rad );
	}
	// ALT above the gauge, its centre over the gauge's middle (inside the
	// screen's right edge), level with JUMP: far enough right of it not to touch
	const CGFloat AR = iosTouch_aButtons[BTN_ALT].radius;
	iosTouch_aButtons[BTN_ALT].x = MIN( MAX( ( gaugeLeft + sz.width ) * 0.5, iosTouch_aButtons[BTN_JUMP].x + iosTouch_aButtons[BTN_JUMP].radius + AR + 24 ),
	                                    right - AR );
	iosTouch_aButtons[BTN_ALT].y = MIN( iosTouch_aButtons[BTN_JUMP].y, gaugeTop - AR - 10 );
	// FORCE up and left of JUMP, over USE
	iosTouch_aButtons[BTN_FORCE].x = iosTouch_aButtons[BTN_USE].x - 20;
	iosTouch_aButtons[BTN_FORCE].y = iosTouch_aButtons[BTN_JUMP].y - 72;

	const int aTopLeft[7] = { BTN_NEXTWPN, BTN_WHEEL, BTN_ITEM, BTN_STYLE, BTN_VIEW, BTN_GYRO, BTN_SETTINGS };
	for ( int i = 0; i < 7; i++ ) {
		iosTouch_aButtons[aTopLeft[i]].x = left + 24 + 58 * i;
		iosTouch_aButtons[aTopLeft[i]].y = top + 26;
	}
	// Top right: QUICK SAVE, QUICK LOAD, MENU in the corner, 66 points apart
	// (10 between where each takes touches), so a press meant for one doesn't
	// land on the next
	iosTouch_aButtons[BTN_QUICKSAVE].x = right - 156;
	iosTouch_aButtons[BTN_QUICKLOAD].x = right - 90;
	iosTouch_aButtons[BTN_MENU].x = right - 24;
	iosTouch_aButtons[BTN_QUICKSAVE].y = iosTouch_aButtons[BTN_QUICKLOAD].y = iosTouch_aButtons[BTN_MENU].y = top + 26;

	for ( int i = 0; i < BTN_COUNT; i++ )
		aButtonViews[i].center = CGPointMake( iosTouch_aButtons[i].x, iosTouch_aButtons[i].y );
	if ( bWheelOpen ) [self layoutWheel];
}

// GYRO stands out in yellow while gyro aiming is on
- (void)refreshGyroLook
{
	aButtonViews[BTN_GYRO].layer.borderColor = iosTouch_bGyro ? [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:0.95].CGColor
	                                                          : [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
	if ( !iosTouch_aHeld[BTN_GYRO] ) aButtonViews[BTN_GYRO].alpha = iosTouch_bGyro ? 1.0 : IOSTOUCH_IDLE_ALPHA;
}

// The nearest button within reach of p (a little outside its circle), or -1
- (int)buttonAt:(CGPoint)p
{
	int best = -1;
	CGFloat bestDist = 0;
	for ( int i = 0; i < BTN_COUNT; i++ ) {
		iosTouchButton *b = &iosTouch_aButtons[i];
		if ( i == BTN_GYRO && !iosTouch_pMotion.deviceMotionAvailable ) continue;
		CGFloat d = hypot( p.x - b->x, p.y - b->y ) - b->radius;
		if ( d <= 6.0 && ( best < 0 || d < bestDist ) ) {
			best = i;
			bestDist = d;
		}
	}
	return best;
}

- (void)setButton:(int)i held:(int)bDown
{
	iosTouchButton *b = &iosTouch_aButtons[i];
	if ( bDown ) {
		if ( iosTouch_aHeld[i]++ == 0 ) {
			if ( b->kind == KIND_HOLD ) iosTouch_SetHeld( b->command, IOSTOUCH_KEYNUM_BASE + i, 1 );
			else if ( b->kind == KIND_TAP ) iosJK_Command( b->command );
			else if ( b->kind == KIND_QUICK || b->kind == KIND_WHEEL ) {
				// KIND_QUICK goes off in -tick, once held long enough;
				// KIND_WHEEL is a tap, a slide or a hold (touches and -tick)
			}
			else if ( b->kind == KIND_SETTINGS ) {
				[self showSettings:settingsPanel.hidden];
			}
			else if ( b->kind == KIND_GYRO ) {
				iosTouch_bGyro = !iosTouch_bGyro;
				[[NSUserDefaults standardUserDefaults] setBool:( iosTouch_bGyro ? YES : NO ) forKey:IOSTOUCH_GYRO_DEFAULTS_KEY];
			}
			else iosJK_Escape( );
		}
	}
	else if ( iosTouch_aHeld[i] > 0 && --iosTouch_aHeld[i] == 0 && b->kind == KIND_HOLD ) {
		iosTouch_SetHeld( b->command, IOSTOUCH_KEYNUM_BASE + i, 0 );
	}
	aButtonViews[i].alpha = iosTouch_aHeld[i] ? 1.0 : IOSTOUCH_IDLE_ALPHA;
	aButtonViews[i].backgroundColor = [UIColor colorWithWhite:( iosTouch_aHeld[i] ? 1.0 : 0.0 ) alpha:( iosTouch_aHeld[i] ? 0.3 : 0.25 )];
	if ( i == BTN_GYRO ) [self refreshGyroLook];
}

// A menu finger at p: the pointer goes under it, in the menus' 640x480
- (void)menuPointerAt:(CGPoint)p
{
	CGSize sz = self.bounds.size;
	iosJK_MenuPointer( (int)( p.x / sz.width * 640.0f ), (int)( p.y / sz.height * 480.0f ) );
}

// ---------------------------------------------------------------- settings panel

// A row: a name, a slider (min..max), and its value on the right
- (UISlider *)addSettingRow:(NSString *)name y:(CGFloat)y min:(float)lo max:(float)hi value:(float)v valueLabel:(UILabel **)pValue
{
	UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake( 16, y, 92, 30 )];
	l.text = name;
	l.textColor = [UIColor whiteColor];
	l.font = [UIFont boldSystemFontOfSize:14];
	[settingsPanel addSubview:l];
	UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake( 110, y, 170, 30 )];
	sl.minimumValue = lo;
	sl.maximumValue = hi;
	sl.value = v;
	[sl addTarget:self action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
	[settingsPanel addSubview:sl];
	UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake( 288, y, 52, 30 )];
	val.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
	val.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
	[settingsPanel addSubview:val];
	*pValue = val;
	return sl;
}

- (void)makeSettingsPanel
{
	settingsPanel = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, 356, 170 )];
	settingsPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
	settingsPanel.layer.cornerRadius = 16;
	settingsPanel.layer.borderWidth = 1.5;
	settingsPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
	settingsPanel.hidden = YES;
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake( 16, 10, 240, 24 )];
	title.text = @"Touch controls";
	title.textColor = [UIColor whiteColor];
	title.font = [UIFont boldSystemFontOfSize:16];
	[settingsPanel addSubview:title];
	lookSlider = [self addSettingRow:@"Look speed" y:46 min:0.5f max:3.0f value:iosTouch_lookSpeed valueLabel:&lookValue];
	gyroSlider = [self addSettingRow:@"Gyro speed" y:86 min:0.5f max:3.0f value:iosTouch_gyroSpeed valueLabel:&gyroValue];
	UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
	done.frame = CGRectMake( 356 - 96, 128, 80, 32 );
	[done setTitle:@"Done" forState:UIControlStateNormal];
	done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
	[done addTarget:self action:@selector(settingsDone:) forControlEvents:UIControlEventTouchUpInside];
	[settingsPanel addSubview:done];
	UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake( 16, 128, 230, 32 )];
	note.text = @"Look: dragging. Gyro: view ° per phone °.";
	note.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
	note.font = [UIFont systemFontOfSize:11];
	note.numberOfLines = 2;
	[settingsPanel addSubview:note];
	[self addSubview:settingsPanel];
	[self refreshSettingValues];
}

- (void)refreshSettingValues
{
	lookValue.text = [NSString stringWithFormat:@"%.1f×", iosTouch_lookSpeed];
	gyroValue.text = [NSString stringWithFormat:@"%.1f", iosTouch_gyroSpeed];
}

// A slider moved: applied at once, and kept (in steps of 0.1)
- (void)settingChanged:(UISlider *)sl
{
	float v = roundf( sl.value * 10.0f ) / 10.0f;
	if ( sl == lookSlider ) {
		iosTouch_lookSpeed = v;
		[[NSUserDefaults standardUserDefaults] setFloat:v forKey:IOSTOUCH_LOOK_SPEED_KEY];
	}
	else {
		iosTouch_gyroSpeed = v;
		[[NSUserDefaults standardUserDefaults] setFloat:v forKey:IOSTOUCH_GYRO_SPEED_KEY];
	}
	[self refreshSettingValues];
}

- (void)settingsDone:(id)sender
{
	[self showSettings:NO];
}

- (void)showSettings:(BOOL)bShow
{
	if ( bShow ) {
		lookSlider.value = iosTouch_lookSpeed;
		gyroSlider.value = iosTouch_gyroSpeed;
		[self refreshSettingValues];
		settingsPanel.center = CGPointMake( self.bounds.size.width * 0.5, self.bounds.size.height * 0.5 );
		[self bringSubviewToFront:settingsPanel];
	}
	settingsPanel.hidden = !bShow;
}

// ---------------------------------------------------------------- force wheel

// A slice's shape: from deg0 round to deg1 (counter-clockwise), radius r0 to r1
static UIBezierPath *IOSTouch_WedgePath( CGPoint c, CGFloat deg0, CGFloat deg1, CGFloat r0, CGFloat r1 )
{
	CGFloat a0 = -deg1 * M_PI / 180.0, a1 = -deg0 * M_PI / 180.0; // UIKit's angles go clockwise
	UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:c radius:r1 startAngle:a0 endAngle:a1 clockwise:YES];
	[p addArcWithCenter:c radius:r0 startAngle:a1 endAngle:a0 clockwise:NO];
	[p closePath];
	return p;
}

// The slice under p (the middle and well outside are -1; the gap cancels)
- (int)wheelSliceAt:(CGPoint)p
{
	CGFloat dx = p.x - wheelCentre.x, dy = wheelCentre.y - p.y;
	CGFloat r = sqrt( dx * dx + dy * dy );
	if ( r < wheelR0 - 4.0 || r > wheelR1 + 24.0 ) return -1;
	return iosTouch_WheelSliceForAngle( pWheel, atan2( dy, dx ) * 180.0 / M_PI );
}

// Round the middle of the safe area, as big as fits
- (void)layoutWheel
{
	CGSize sz = self.bounds.size;
	UIEdgeInsets in = self.safeAreaInsets;
	CGFloat top = MAX( in.top, 8.0 ), bottom = sz.height - MAX( in.bottom, 8.0 );
	wheelCentre = CGPointMake( sz.width * 0.5, ( top + bottom ) * 0.5 );
	wheelR1 = MIN( 160.0, ( bottom - top ) * 0.5 - 10.0 );
	wheelR0 = round( wheelR1 * 0.37 );
	for ( int i = 0; i < IOSTOUCH_WHEEL_MAX; i++ ) {
		aSliceLayers[i].hidden = aSliceLabels[i].hidden = i >= pWheel->numSlices;
		if ( i >= pWheel->numSlices ) continue;
		CGFloat a = pWheel->aSlices[i].deg * M_PI / 180.0;
		CGFloat r = ( wheelR0 + wheelR1 ) * 0.5 + 4.0;
		aSliceLabels[i].center = CGPointMake( wheelCentre.x + r * cos( a ), wheelCentre.y - r * sin( a ) );
	}
	wheelTitle.center = CGPointMake( wheelCentre.x, wheelCentre.y - 7.0 );
	wheelTitle.bounds = CGRectMake( 0, 0, wheelR0 * 1.7, 24 );
	wheelHint.center = CGPointMake( wheelCentre.x, wheelCentre.y + 13.0 );
	wheelHint.bounds = CGRectMake( 0, 0, wheelR0 * 1.9, 14 );
	[self refreshWheel];
}

// Each slice in its look (learned in its group's colour, the selected one
// edged in white, the one pointed at bright and popped out, the rest dark),
// and the middle: what lifting would pick, or what to do
- (void)refreshWheel
{
	if ( !bWheelOpen ) return;
	int hot = -1, bCancel = 0;
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		iosTouchSlot *s = &iosTouch_aSlots[i];
		if ( s->touch && s->role == ROLE_WHEEL ) {
			hot = s->wheelSlot;
			bCancel = hot == IOSTOUCH_WHEEL_CANCEL;
		}
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for ( int i = 0; i < pWheel->numSlices; i++ ) {
		const iosTouchWheelSlice *sl = &pWheel->aSlices[i];
		int bLearned = ( wheelLearned >> i ) & 1;
		int bHot = i == hot;
		CGFloat half = pWheel->sliceDeg * 0.5 - 1.0;
		aSliceLayers[i].path = IOSTouch_WedgePath( wheelCentre, sl->deg - half, sl->deg + half, wheelR0,
		                                           wheelR1 + ( bHot && bLearned ? 10.0 : 0.0 ) ).CGPath;
		UIColor *full = [UIColor colorWithRed:sl->r / 255.0 green:sl->g / 255.0 blue:sl->b / 255.0 alpha:1.0];
		if ( !bLearned ) {
			aSliceLayers[i].fillColor = [UIColor colorWithWhite:( bHot ? 0.24 : 0.16 ) alpha:0.92].CGColor;
			aSliceLayers[i].strokeColor = [full colorWithAlphaComponent:0.4].CGColor;
			aSliceLabels[i].textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
		}
		else if ( bHot ) {
			aSliceLayers[i].fillColor = full.CGColor;
			aSliceLayers[i].strokeColor = [UIColor whiteColor].CGColor;
			aSliceLabels[i].textColor = [UIColor colorWithWhite:0.08 alpha:1.0];
		}
		else {
			aSliceLayers[i].fillColor = [full colorWithAlphaComponent:0.35].CGColor;
			aSliceLayers[i].strokeColor = ( i == wheelSelected ) ? [UIColor whiteColor].CGColor : [full colorWithAlphaComponent:0.8].CGColor;
			aSliceLabels[i].textColor = [UIColor whiteColor];
		}
		aSliceLayers[i].lineWidth = ( bHot || i == wheelSelected ) ? 3.0 : 2.0;
		// the name, and a star per level learned, or how many are carried
		NSString *name = [NSString stringWithUTF8String:sl->name];
		if ( !bLearned ) aSliceLabels[i].text = name;
		else if ( pWheel->bCounts ) aSliceLabels[i].text = aWheelLevels[i] > 1 ? [NSString stringWithFormat:@"%@\n×%d", name, aWheelLevels[i]] : name;
		else aSliceLabels[i].text = [NSString stringWithFormat:@"%@\n%@", name, [@"★★★" substringToIndex:MAX( 0, MIN( 3, aWheelLevels[i] ) )]];
	}
	[CATransaction commit];

	if ( hot >= 0 ) {
		wheelTitle.text = [[[NSString stringWithUTF8String:pWheel->aSlices[hot].name] stringByReplacingOccurrencesOfString:@"-\n" withString:@""] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
		wheelHint.text = [NSString stringWithUTF8String:( ( wheelLearned >> hot ) & 1 ) ? pWheel->liftHint : pWheel->notThere];
	}
	else if ( bCancel ) {
		wheelTitle.text = @"CANCEL";
		wheelHint.text = @"lift to cancel";
	}
	else if ( !wheelLearned ) {
		wheelTitle.text = [NSString stringWithUTF8String:pWheel->emptyTitle];
		wheelHint.text = [NSString stringWithUTF8String:pWheel->emptyHint];
	}
	else {
		int sel = ( wheelSelected >= 0 && wheelSelected < pWheel->numSlices && ( ( wheelLearned >> wheelSelected ) & 1 ) ) ? wheelSelected : -1;
		wheelTitle.text = sel >= 0 ? [[[NSString stringWithUTF8String:pWheel->aSlices[sel].name] stringByReplacingOccurrencesOfString:@"-\n" withString:@""] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
		                           : [NSString stringWithUTF8String:pWheel->title];
		wheelHint.text = bWheelTapMode ? @"tap one" : @"slide toward one";
	}
	wheelTitle.textColor = [UIColor whiteColor];
	if ( hot != wheelLastHot ) {
		if ( hot != -1 ) [wheelTick selectionChanged];
		wheelLastHot = hot;
	}
}

// Opens the wheel: every other touch lets go of what it held and is ignored
// until it lifts; the opener (if sliding) points by direction
- (void)openWheelWithOpener:(iosTouchSlot *)opener tapMode:(int)bTap
{
	pWheel = ( opener && opener->button == BTN_ITEM ) ? &iosTouch_itemWheel : &iosTouch_forceWheel;
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		iosTouchSlot *s = &iosTouch_aSlots[i];
		if ( !s->touch || s == opener ) continue;
		if ( s->role == ROLE_BUTTON ) {
			if ( iosTouch_aButtons[s->button].kind == KIND_QUICK ) [self setRing:s->button progress:0.0];
			[self setButton:s->button held:0];
		}
		else if ( s->role == ROLE_STICK ) {
			bStickActive = 0;
			iosTouch_SetStick( 0, 0, 0 );
			stickBase.hidden = YES;
			stickKnob.hidden = YES;
		}
		s->role = ROLE_IGNORED;
	}
	if ( !iosJK_GetWheelInfo( pWheel->infoCvar, &wheelLearned, &wheelSelected, aWheelLevels, pWheel->numSlices ) ) {
		wheelLearned = 0;
		wheelSelected = -1;
	}
	bWheelOpen = 1;
	bWheelTapMode = bTap;
	wheelLastHot = -1;
	if ( opener ) {
		opener->role = bTap ? ROLE_IGNORED : ROLE_WHEEL;
		opener->bOpener = 1;
		opener->wheelSlot = -1;
	}
	[self layoutWheel];
	wheelView.hidden = NO;
	[self bringSubviewToFront:wheelView];
	[wheelTick prepare];
	[self refreshWheel];
}

// Closes the wheel, selecting slice if it's a learned power
- (void)closeWheelSelecting:(int)slice
{
	if ( pWheel && slice >= 0 && slice < pWheel->numSlices && ( ( wheelLearned >> slice ) & 1 ) ) {
		char line[32];
		snprintf( line, sizeof( line ), "%s %d\n", pWheel->selectCmd, slice );
		iosJK_Command( line );
		if ( pWheel->afterSelect ) iosJK_Command( pWheel->afterSelect );
	}
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		if ( iosTouch_aSlots[i].touch && iosTouch_aSlots[i].role == ROLE_WHEEL ) iosTouch_aSlots[i].role = ROLE_IGNORED;
	}
	bWheelOpen = 0;
	bWheelTapMode = 0;
	wheelView.hidden = YES;
}

// The sliding opener at p: the slice under it if it's on the wheel, else the
// one its direction from where it went down points to; nothing back near there
- (void)aimWheel:(iosTouchSlot *)s at:(CGPoint)p
{
	int on = [self wheelSliceAt:p];
	if ( on != -1 ) {
		s->wheelSlot = on;
		return;
	}
	CGFloat dx = p.x - s->origin.x, dy = s->origin.y - p.y;
	if ( hypot( dx, dy ) < IOSTOUCH_WHEEL_DEAD ) {
		s->wheelSlot = -1;
		return;
	}
	s->wheelSlot = iosTouch_WheelSliceForAngle( pWheel, atan2( dy, dx ) * 180.0 / M_PI );
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for ( UITouch *t in touches ) {
		// on the ⚙︎ panel (its sliders and Done take their own touches)
		if ( !settingsPanel.hidden && [t.view isDescendantOfView:settingsPanel] ) continue;
		// A video: a tap skips it
		if ( iosJK_IsCinematic( ) ) {
			iosJK_Escape( );
			continue;
		}
		// A menu: one finger at a time points and clicks
		if ( iosJK_InMenu( ) ) {
			if ( bMenuFingerDown ) continue;
			int slot = -1;
			for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
				if ( !iosTouch_aSlots[i].touch ) { slot = i; break; }
			}
			if ( slot < 0 ) continue;
			iosTouchSlot *s = &iosTouch_aSlots[slot];
			s->touch = t;
			s->role = ROLE_MENU;
			bMenuFingerDown = 1;
			[self menuPointerAt:[t locationInView:self]];
			iosJK_MenuButton( 1 );
			continue;
		}
		int slot = -1;
		for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
			if ( !iosTouch_aSlots[i].touch ) { slot = i; break; }
		}
		if ( slot < 0 ) continue;
		CGPoint p = [t locationInView:self];
		iosTouchSlot *s = &iosTouch_aSlots[slot];
		memset( s, 0, sizeof( *s ) );
		s->touch = t;
		s->origin = s->last = p;
		s->tDown = CACurrentMediaTime( );
		if ( bWheelOpen ) {
			// the wheel takes every touch: the slice under it
			s->role = ROLE_WHEEL;
			s->wheelSlot = [self wheelSliceAt:p];
			[self refreshWheel];
			continue;
		}
		s->button = [self buttonAt:p];
		if ( s->button >= 0 && iosTouch_aButtons[s->button].kind == KIND_WHEEL ) {
			s->role = ROLE_WHEELBTN;
			[self setButton:s->button held:1];
		}
		else if ( s->button >= 0 ) {
			s->role = ROLE_BUTTON;
			[self setButton:s->button held:1];
		}
		else if ( p.x < self.bounds.size.width * IOSTOUCH_STICK_ZONE && !bStickActive ) {
			s->role = ROLE_STICK;
			bStickActive = 1;
			stickBase.center = p;
			stickKnob.center = p;
			stickBase.hidden = NO;
			stickKnob.hidden = NO;
		}
		else {
			s->role = ROLE_LOOK;
		}
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for ( UITouch *t in touches ) {
		for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
			iosTouchSlot *s = &iosTouch_aSlots[i];
			if ( s->touch != t ) continue;
			CGPoint p = [t locationInView:self];
			if ( s->role == ROLE_MENU ) {
				[self menuPointerAt:p];
			}
			else if ( s->role == ROLE_WHEELBTN ) {
				// slid out of FORCE WHEEL: the wheel opens, pointing the slide's way
				if ( hypot( p.x - s->origin.x, p.y - s->origin.y ) >= IOSTOUCH_WHEEL_DEAD ) {
					[self setButton:s->button held:0];
					[self openWheelWithOpener:s tapMode:0];
					[self aimWheel:s at:p];
					[self refreshWheel];
				}
			}
			else if ( s->role == ROLE_WHEEL ) {
				if ( s->bOpener ) [self aimWheel:s at:p];
				else s->wheelSlot = [self wheelSliceAt:p];
				[self refreshWheel];
			}
			else if ( s->role == ROLE_STICK ) {
				float dx = ( p.x - s->origin.x ) / IOSTOUCH_STICK_RADIUS;
				float dy = ( p.y - s->origin.y ) / IOSTOUCH_STICK_RADIUS;
				float len = sqrtf( dx * dx + dy * dy );
				if ( len > 1.0f ) { dx /= len; dy /= len; }
				iosTouch_SetStick( dx, dy, 1 );
				stickKnob.center = CGPointMake( s->origin.x + dx * IOSTOUCH_STICK_RADIUS, s->origin.y + dy * IOSTOUCH_STICK_RADIUS );
			}
			else if ( s->role == ROLE_BUTTON && iosTouch_aButtons[s->button].kind == KIND_QUICK ) {
				// slid off: no save or load from this touch, even back on
				iosTouchButton *b = &iosTouch_aButtons[s->button];
				if ( !s->bFired && hypot( p.x - b->x, p.y - b->y ) > b->radius + 6.0 ) {
					s->bFired = 1;
					[self setRing:s->button progress:0.0];
				}
			}
			else if ( s->role == ROLE_LOOK || ( s->role == ROLE_BUTTON && iosTouch_aButtons[s->button].bLookWhileHeld ) ) {
				iosTouch_lookX += ( p.x - s->last.x ) * IOSTOUCH_LOOK_SCALE_X * iosTouch_lookSpeed;
				iosTouch_lookY += ( p.y - s->last.y ) * IOSTOUCH_LOOK_SCALE_Y * iosTouch_lookSpeed;
			}
			s->last = p;
		}
	}
}

- (void)endTouches:(NSSet<UITouch *> *)touches
{
	for ( UITouch *t in touches ) {
		for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
			iosTouchSlot *s = &iosTouch_aSlots[i];
			if ( s->touch != t ) continue;
			CGPoint p = [t locationInView:self];
			if ( s->role == ROLE_WHEELBTN ) {
				// a quick tap: the next learned power / uses the selected item
				[self setButton:s->button held:0];
				iosJK_Command( iosTouch_aButtons[s->button].command );
			}
			else if ( s->role == ROLE_WHEEL && bWheelOpen ) {
				if ( s->bOpener ) {
					[self aimWheel:s at:p];
					[self closeWheelSelecting:s->wheelSlot]; // a learned power, or no change
				}
				else {
					// a tap: a learned power selects it; one not learned yet
					// leaves the wheel open; anywhere else closes it
					int slice = [self wheelSliceAt:p];
					if ( !( slice >= 0 && !( ( wheelLearned >> slice ) & 1 ) ) ) [self closeWheelSelecting:slice];
					else s->wheelSlot = -1;
				}
				[self refreshWheel];
			}
			else if ( s->role == ROLE_BUTTON ) {
				if ( iosTouch_aButtons[s->button].kind == KIND_QUICK ) [self setRing:s->button progress:0.0];
				[self setButton:s->button held:0];
			}
			else if ( s->role == ROLE_MENU ) {
				[self menuPointerAt:[t locationInView:self]];
				iosJK_MenuButton( 0 );
				bMenuFingerDown = 0;
			}
			else if ( s->role == ROLE_STICK ) {
				bStickActive = 0;
				iosTouch_SetStick( 0, 0, 0 );
				stickBase.hidden = YES;
				stickKnob.hidden = YES;
			}
			memset( s, 0, sizeof( *s ) );
		}
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }

- (void)setRing:(int)i progress:(CGFloat)progress
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	aQuickRings[i].strokeEnd = progress;
	[CATransaction commit];
}

// Once per frame while playing: QUICK SAVE and QUICK LOAD fill their rings
// while held, and go off once full (the first to fill ends every other hold)
- (void)tick
{
	CFTimeInterval now = CACurrentMediaTime( );
	// FORCE WHEEL held without sliding: the wheel opens and stays open
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		iosTouchSlot *s = &iosTouch_aSlots[i];
		if ( s->touch && s->role == ROLE_WHEELBTN && now - s->tDown >= IOSTOUCH_WHEEL_HOLD ) {
			[self setButton:s->button held:0];
			[self openWheelWithOpener:s tapMode:1];
		}
	}
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		iosTouchSlot *s = &iosTouch_aSlots[i];
		if ( !s->touch || s->role != ROLE_BUTTON || s->bFired || iosTouch_aButtons[s->button].kind != KIND_QUICK ) continue;
		CGFloat progress = (CGFloat)( ( now - s->tDown ) / IOSTOUCH_QUICK_HOLD );
		if ( progress < 1.0 ) {
			[self setRing:s->button progress:progress];
			continue;
		}
		iosJK_Command( iosTouch_aButtons[s->button].command );
		for ( int k = 0; k < IOSTOUCH_MAX_TOUCHES; k++ ) {
			iosTouchSlot *o = &iosTouch_aSlots[k];
			if ( o->touch && o->role == ROLE_BUTTON && iosTouch_aButtons[o->button].kind == KIND_QUICK ) {
				o->bFired = 1;
				[self setRing:o->button progress:0.0];
			}
		}
	}
}

// No gyroscope: GYRO stays hidden
- (void)viewWithGyroHidden
{
	aButtonViews[BTN_GYRO].hidden = YES;
}

// Lets go of everything: touches on a hidden view never end
- (void)releaseAll
{
	if ( bWheelOpen ) [self closeWheelSelecting:-1];
	[self showSettings:NO];
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		iosTouchSlot *s = &iosTouch_aSlots[i];
		if ( s->touch && s->role == ROLE_BUTTON ) [self setButton:s->button held:0];
		if ( s->touch && s->role == ROLE_MENU ) iosJK_MenuButton( 0 );
		memset( s, 0, sizeof( *s ) );
	}
	for ( int i = 0; i < BTN_COUNT; i++ ) {
		while ( iosTouch_aHeld[i] ) [self setButton:i held:0];
	}
	bStickActive = 0;
	bMenuFingerDown = 0;
	for ( int i = 0; i < BTN_COUNT; i++ ) {
		if ( aQuickRings[i] ) [self setRing:i progress:0.0];
	}
	iosTouch_SetStick( 0, 0, 0 );
	stickBase.hidden = YES;
	stickKnob.hidden = YES;
	iosTouch_lookX = iosTouch_lookY = 0.0f;
}

@end

// ---------------------------------------------------------------- C API

void iosWin_SetDrawableHeight( SDL_Window *window, int height )
{
	@autoreleasepool {
		SDL_SysWMinfo info;
		SDL_VERSION( &info.version );
		if ( !window || !SDL_GetWindowWMInfo( window, &info ) || info.subsystem != SDL_SYSWM_UIKIT ) return;
		UIWindow *w = info.info.uikit.window;
		UIView *view = w.rootViewController.view; // SDL's GL view (SDL_uikitopenglview)
		if ( !view ) return;
		CGFloat pointsHigh = MIN( view.bounds.size.width, view.bounds.size.height ); // landscape
		if ( pointsHigh <= 0 ) return;
		CGFloat scale = height / pointsHigh;
		scale = MAX( 1.0, MIN( scale, w.screen.nativeScale ) );
		view.contentScaleFactor = scale;
		// its layoutSubviews makes the GL buffers that size
		[view setNeedsLayout];
		[view layoutIfNeeded];
	}
}

static IOSTouchOverlay *iosTouch_pOverlay = nil;

static UIView *iosTouch_GetHostView( void )
{
	SDL_Window *window = SDL_GL_GetCurrentWindow( );
	if ( !window ) return nil;
	SDL_SysWMinfo info;
	SDL_VERSION( &info.version );
	if ( !SDL_GetWindowWMInfo( window, &info ) || info.subsystem != SDL_SYSWM_UIKIT ) return nil;
	UIWindow *w = info.info.uikit.window;
	return w.rootViewController.view ? w.rootViewController.view : w;
}

void iosTouch_Update( void )
{
	@autoreleasepool {
		int bPlaying = iosJK_IsPlaying( );
		int bMenu = iosJK_InMenu( );
		int bWant = bPlaying || bMenu || iosJK_IsCinematic( );
		// Playing, a menu or a video: whatever was held lets go when that changes
		static int lastMode = -1;
		int mode = bPlaying ? 1 : ( bMenu ? 2 : 3 );

		UIView *host = iosTouch_GetHostView( );
		if ( !iosTouch_pOverlay ) {
			if ( !bWant || !host ) return;
			iosTouch_pOverlay = [[IOSTouchOverlay alloc] initWithFrame:host.bounds];
			[host addSubview:iosTouch_pOverlay];
		}
		else if ( host && iosTouch_pOverlay.superview != host ) {
			// the SDL window was made again (a video restart): follow it
			[iosTouch_pOverlay removeFromSuperview];
			iosTouch_pOverlay.frame = host.bounds;
			[host addSubview:iosTouch_pOverlay];
			[iosTouch_pOverlay releaseAll];
		}
		if ( iosTouch_pOverlay.superview.subviews.lastObject != iosTouch_pOverlay )
			[iosTouch_pOverlay.superview bringSubviewToFront:iosTouch_pOverlay];

		if ( (int)iosTouch_pOverlay.hidden == bWant ) {
			iosTouch_pOverlay.hidden = !bWant;
			[iosTouch_pOverlay releaseAll];
		}
		else if ( mode != lastMode ) {
			[iosTouch_pOverlay releaseAll];
		}
		lastMode = mode;
		// A video or a menu: the overlay takes taps (to skip, to click); no buttons
		for ( UIView *v in iosTouch_pOverlay.subviews ) {
			if ( [v isKindOfClass:[UILabel class]] ) v.hidden = !bPlaying;
		}
		if ( !iosTouch_pMotion.deviceMotionAvailable ) [iosTouch_pOverlay viewWithGyroHidden];

		iosTouch_UpdateGyro( bPlaying, iosTouch_pOverlay );
		if ( bPlaying ) [iosTouch_pOverlay tick];

		if ( bPlaying ) {
			int dx = (int)iosTouch_lookX, dy = (int)iosTouch_lookY;
			iosTouch_lookX -= dx;
			iosTouch_lookY -= dy;
			iosJK_Look( dx, dy );
		}
	}
}
