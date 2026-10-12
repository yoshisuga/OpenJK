// iOS: on-screen touch controls, a UIKit overlay over SDL's window, modelled
// on OpenJKDF2's iOS port. While a level is being played (iosJK_IsPlaying):
//   - a floating move stick under the left thumb (+forward/+back/
//     +moveleft/+moveright)
//   - drag anywhere else to look (fed in as mouse movement); dragging on
//     FIRE or ALT looks too, so a thumb that lands on one while aiming keeps
//     aiming
//   - bottom right: FIRE (+attack), ALT (+altattack), JUMP (+moveup),
//     CROUCH (+movedown), USE (+use), FORCE (+useforce, the selected power)
//   - top left: NEXT WPN (weapnext), NEXT FORCE (forcenext), ITEM (invuse),
//     VIEW (cg_thirdperson !), GYRO; top right: MENU (Escape, which also
//     skips an in-game cutscene)
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
#define IOSTOUCH_GYRO_SCALE 1.5
#define IOSTOUCH_GYRO_TIGHTEN 3.0
#define IOSTOUCH_GYRO_HZ 100.0
#define IOSTOUCH_GYRO_MAX_GAP 0.1
#define IOSTOUCH_GYRO_DEFAULTS_KEY @"iosTouchGyro"

enum { KIND_HOLD, KIND_TAP, KIND_MENU, KIND_GYRO };

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
	BTN_NEXTWPN, BTN_NEXTFORCE, BTN_ITEM, BTN_VIEW, BTN_GYRO, BTN_MENU,
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
	[BTN_NEXTFORCE] = { "NEXT\nFORCE", KIND_TAP,  "forcenext\n", 22.0f, 0 },
	[BTN_ITEM]      = { "ITEM",        KIND_TAP,  "invuse\n",   22.0f, 0 },
	[BTN_VIEW]      = { "VIEW",        KIND_TAP,  "cg_thirdperson !\n", 22.0f, 0 },
	[BTN_GYRO]      = { "GYRO",        KIND_GYRO, NULL,         22.0f, 0 },
	[BTN_MENU]      = { "MENU",        KIND_MENU, NULL,         22.0f, 0 },
};

enum { ROLE_NONE, ROLE_STICK, ROLE_LOOK, ROLE_BUTTON, ROLE_MENU };

typedef struct {
	UITouch *touch; // not retained; only compared
	int role;
	int button;
	CGPoint origin;
	CGPoint last;
} iosTouchSlot;

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
	double rx, ry, gx, gy;
	switch ( iosTouch_gyroOrientation ) {
		case UIInterfaceOrientationLandscapeRight: // the phone's top on the left
			rx = -r.y; ry = r.x; gx = -g.y; gy = g.x;
			break;
		case UIInterfaceOrientationLandscapeLeft:  // the phone's top on the right
			rx = r.y; ry = -r.x; gx = g.y; gy = -g.x;
			break;
		case UIInterfaceOrientationPortraitUpsideDown:
			rx = -r.x; ry = -r.y; gx = -g.x; gy = -g.y;
			break;
		default:
			rx = r.x; ry = r.y; gx = g.x; gy = g.y;
			break;
	}
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

	// only this queue's blocks touch lastT, one at a time
	__block NSTimeInterval lastT = 0.0;
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
	if ( fabsf( yawDeg ) > 1e-6f ) iosTouch_lookX += (float)( right * IOSTOUCH_GYRO_SCALE / fabsf( yawDeg ) );
	if ( fabsf( pitchDeg ) > 1e-6f ) iosTouch_lookY -= (float)( up * IOSTOUCH_GYRO_SCALE / pitchDeg );
}

// ---------------------------------------------------------------- overlay view

@interface IOSTouchOverlay : UIView {
	int bMenuFingerDown;
	UILabel *aButtonViews[BTN_COUNT];
	UIView *stickBase;
	UIView *stickKnob;
	int bStickActive;
}
- (void)releaseAll;
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

	const int aTopLeft[5] = { BTN_NEXTWPN, BTN_NEXTFORCE, BTN_ITEM, BTN_VIEW, BTN_GYRO };
	for ( int i = 0; i < 5; i++ ) {
		iosTouch_aButtons[aTopLeft[i]].x = left + 24 + 58 * i;
		iosTouch_aButtons[aTopLeft[i]].y = top + 26;
	}
	iosTouch_aButtons[BTN_MENU].x = right - 24;
	iosTouch_aButtons[BTN_MENU].y = top + 26;

	for ( int i = 0; i < BTN_COUNT; i++ )
		aButtonViews[i].center = CGPointMake( iosTouch_aButtons[i].x, iosTouch_aButtons[i].y );
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

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for ( UITouch *t in touches ) {
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
		s->touch = t;
		s->origin = s->last = p;
		s->button = [self buttonAt:p];
		if ( s->button >= 0 ) {
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
			else if ( s->role == ROLE_STICK ) {
				float dx = ( p.x - s->origin.x ) / IOSTOUCH_STICK_RADIUS;
				float dy = ( p.y - s->origin.y ) / IOSTOUCH_STICK_RADIUS;
				float len = sqrtf( dx * dx + dy * dy );
				if ( len > 1.0f ) { dx /= len; dy /= len; }
				iosTouch_SetStick( dx, dy, 1 );
				stickKnob.center = CGPointMake( s->origin.x + dx * IOSTOUCH_STICK_RADIUS, s->origin.y + dy * IOSTOUCH_STICK_RADIUS );
			}
			else if ( s->role == ROLE_LOOK || ( s->role == ROLE_BUTTON && iosTouch_aButtons[s->button].bLookWhileHeld ) ) {
				iosTouch_lookX += ( p.x - s->last.x ) * IOSTOUCH_LOOK_SCALE_X;
				iosTouch_lookY += ( p.y - s->last.y ) * IOSTOUCH_LOOK_SCALE_Y;
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
			if ( s->role == ROLE_BUTTON ) [self setButton:s->button held:0];
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

// No gyroscope: GYRO stays hidden
- (void)viewWithGyroHidden
{
	aButtonViews[BTN_GYRO].hidden = YES;
}

// Lets go of everything: touches on a hidden view never end
- (void)releaseAll
{
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

		if ( bPlaying ) {
			int dx = (int)iosTouch_lookX, dy = (int)iosTouch_lookY;
			iosTouch_lookX -= dx;
			iosTouch_lookY -= dy;
			iosJK_Look( dx, dy );
		}
	}
}
