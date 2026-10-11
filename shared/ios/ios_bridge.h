// iOS: see ios_bridge.cpp and ios_touch.m.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Playing a level: no menu, console or video in front of it
int iosJK_IsPlaying( void );
// A video (cinematic) is playing; Escape skips it
int iosJK_IsCinematic( void );
// Adds a command line ("+attack 1000\n") to the command buffer
void iosJK_Command( const char *text );
// Turns the view, as mouse movement
void iosJK_Look( int dx, int dy );
// One press of Escape: the menu, or skips a cutscene or video
void iosJK_Escape( void );

// Called once per frame (IN_Frame), before events are processed: shows or
// hides the overlay and sends the look movement gathered since last time
void iosTouch_Update( void );

#ifdef __cplusplus
}
#endif
