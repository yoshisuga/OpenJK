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
//     VIEW (cg_thirdperson !); top right: MENU (Escape, which also skips an
//     in-game cutscene)
// The buttons run the game's commands, not keys, so they don't depend on the
// key bindings. While a video plays, a tap anywhere skips it (Escape). In
// the menus the overlay is hidden, so touches reach SDL as before.
// Written for manual reference counting or ARC (the overlay lives for the
// whole process).

#import <UIKit/UIKit.h>
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

enum { KIND_HOLD, KIND_TAP, KIND_MENU };

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
	BTN_NEXTWPN, BTN_NEXTFORCE, BTN_ITEM, BTN_VIEW, BTN_MENU,
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
	[BTN_MENU]      = { "MENU",        KIND_MENU, NULL,         22.0f, 0 },
};

enum { ROLE_NONE, ROLE_STICK, ROLE_LOOK, ROLE_BUTTON };

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

// ---------------------------------------------------------------- overlay view

@interface IOSTouchOverlay : UIView {
	UILabel *aButtonViews[BTN_COUNT];
	UIView *stickBase;
	UIView *stickKnob;
	int bStickActive;
}
- (void)releaseAll;
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
		stickBase = IOSTouch_MakeCircle( IOSTOUCH_STICK_RADIUS, 0.08 );
		stickKnob = IOSTouch_MakeCircle( IOSTOUCH_STICK_KNOB, 0.30 );
		stickBase.hidden = YES;
		stickKnob.hidden = YES;
		[self addSubview:stickBase];
		[self addSubview:stickKnob];
	}
	return self;
}

// Bottom right, under the right thumb: FIRE in the corner, JUMP above it,
// CROUCH to its left, USE between them on the arc, ALT up and to the right,
// FORCE left of JUMP. Top left: NEXT WPN, NEXT FORCE, ITEM, VIEW; top right:
// MENU. All inside the safe area (the cutout, the home bar).
- (void)layoutSubviews
{
	[super layoutSubviews];
	CGSize sz = self.bounds.size;
	UIEdgeInsets in = self.safeAreaInsets;
	CGFloat left = MAX( in.left, 8.0 ), right = sz.width - MAX( in.right, 8.0 );
	CGFloat top = MAX( in.top, 8.0 ), bottom = sz.height - MAX( in.bottom, 8.0 );

	CGPoint fire = CGPointMake( right - 60, bottom - 56 );
	iosTouch_aButtons[BTN_FIRE].x = fire.x;
	iosTouch_aButtons[BTN_FIRE].y = fire.y;
	const CGFloat arc = 112.0;
	const int aArc[3] = { BTN_CROUCH, BTN_USE, BTN_JUMP };
	const CGFloat aDeg[3] = { 180.0, 135.0, 90.0 };
	for ( int i = 0; i < 3; i++ ) {
		CGFloat rad = aDeg[i] * M_PI / 180.0;
		iosTouch_aButtons[aArc[i]].x = fire.x + arc * cos( rad );
		iosTouch_aButtons[aArc[i]].y = fire.y - arc * sin( rad );
	}
	iosTouch_aButtons[BTN_ALT].x = MIN( fire.x + 50, right - iosTouch_aButtons[BTN_ALT].radius );
	iosTouch_aButtons[BTN_ALT].y = fire.y - 95;
	iosTouch_aButtons[BTN_FORCE].x = iosTouch_aButtons[BTN_JUMP].x - 80;
	iosTouch_aButtons[BTN_FORCE].y = iosTouch_aButtons[BTN_JUMP].y - 30;

	const int aTopLeft[4] = { BTN_NEXTWPN, BTN_NEXTFORCE, BTN_ITEM, BTN_VIEW };
	for ( int i = 0; i < 4; i++ ) {
		iosTouch_aButtons[aTopLeft[i]].x = left + 24 + 58 * i;
		iosTouch_aButtons[aTopLeft[i]].y = top + 26;
	}
	iosTouch_aButtons[BTN_MENU].x = right - 24;
	iosTouch_aButtons[BTN_MENU].y = top + 26;

	for ( int i = 0; i < BTN_COUNT; i++ )
		aButtonViews[i].center = CGPointMake( iosTouch_aButtons[i].x, iosTouch_aButtons[i].y );
}

// The nearest button within reach of p (a little outside its circle), or -1
- (int)buttonAt:(CGPoint)p
{
	int best = -1;
	CGFloat bestDist = 0;
	for ( int i = 0; i < BTN_COUNT; i++ ) {
		iosTouchButton *b = &iosTouch_aButtons[i];
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
			else iosJK_Escape( );
		}
	}
	else if ( iosTouch_aHeld[i] > 0 && --iosTouch_aHeld[i] == 0 && b->kind == KIND_HOLD ) {
		iosTouch_SetHeld( b->command, IOSTOUCH_KEYNUM_BASE + i, 0 );
	}
	aButtonViews[i].alpha = iosTouch_aHeld[i] ? 1.0 : IOSTOUCH_IDLE_ALPHA;
	aButtonViews[i].backgroundColor = [UIColor colorWithWhite:( iosTouch_aHeld[i] ? 1.0 : 0.0 ) alpha:( iosTouch_aHeld[i] ? 0.3 : 0.25 )];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for ( UITouch *t in touches ) {
		// A video: a tap skips it
		if ( iosJK_IsCinematic( ) ) {
			iosJK_Escape( );
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
			if ( s->role == ROLE_STICK ) {
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

// Lets go of everything: touches on a hidden view never end
- (void)releaseAll
{
	for ( int i = 0; i < IOSTOUCH_MAX_TOUCHES; i++ ) {
		iosTouchSlot *s = &iosTouch_aSlots[i];
		if ( s->touch && s->role == ROLE_BUTTON ) [self setButton:s->button held:0];
		memset( s, 0, sizeof( *s ) );
	}
	for ( int i = 0; i < BTN_COUNT; i++ ) {
		while ( iosTouch_aHeld[i] ) [self setButton:i held:0];
	}
	bStickActive = 0;
	iosTouch_SetStick( 0, 0, 0 );
	stickBase.hidden = YES;
	stickKnob.hidden = YES;
	iosTouch_lookX = iosTouch_lookY = 0.0f;
}

@end

// ---------------------------------------------------------------- C API

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
		int bWant = bPlaying || iosJK_IsCinematic( );

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
		// A video: the overlay only takes taps (to skip); no buttons
		for ( UIView *v in iosTouch_pOverlay.subviews ) {
			if ( [v isKindOfClass:[UILabel class]] ) v.hidden = !bPlaying;
		}

		if ( bPlaying ) {
			int dx = (int)iosTouch_lookX, dy = (int)iosTouch_lookY;
			iosTouch_lookX -= dx;
			iosTouch_lookY -= dy;
			iosJK_Look( dx, dy );
		}
	}
}
