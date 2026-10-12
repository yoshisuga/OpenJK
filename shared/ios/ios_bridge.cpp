// iOS: the engine side of the touch overlay (ios_touch.m). The overlay is
// Objective-C and can't include the engine's headers, so everything it needs
// from the game goes through these plain C functions.

#include "ios_bridge.h"

#include "client/client.h"
#include "sys/sys_local.h"

void _UI_MouseEvent( int dx, int dy ); // ui_main.cpp (the single player UI is part of the engine)

extern "C" {

int iosJK_IsPlaying( void )
{
	return cls.state == CA_ACTIVE && !( Key_GetCatcher( ) & ( KEYCATCH_UI | KEYCATCH_CONSOLE ) );
}

int iosJK_IsCinematic( void )
{
	return cls.state == CA_CINEMATIC;
}

int iosJK_InMenu( void )
{
	return ( Key_GetCatcher( ) & KEYCATCH_UI ) != 0;
}

void iosJK_Command( const char *text )
{
	Com_Printf( "iOS touch: %s", text ); // spike diagnostic
	Cbuf_AddText( text );
}

void iosJK_MenuPointer( int x, int y )
{
	// Straight to the menu: queued mouse moves are merged into one, so "to the
	// top left (where the menu clamps it), then out to x, y" can't be queued
	_UI_MouseEvent( -100000, -100000 );
	_UI_MouseEvent( x, y );
}

void iosJK_MenuButton( int bDown )
{
	Sys_QueEvent( 0, SE_KEY, A_MOUSE1, bDown ? qtrue : qfalse, 0, NULL );
}

void iosJK_GetMouseDegrees( float *pYaw, float *pPitch )
{
	// as CL_MouseMove turns the view: degrees per count of mouse movement
	// (cgameSensitivity: less while zoomed)
	const float s = cl_sensitivity->value * cl.cgameSensitivity;
	*pYaw = m_yaw->value * s;
	*pPitch = m_pitch->value * s;
}

void iosJK_Look( int dx, int dy )
{
	if ( dx || dy )
		Sys_QueEvent( 0, SE_MOUSE, dx, dy, 0, NULL );
}

void iosJK_Escape( void )
{
	Sys_QueEvent( 0, SE_KEY, A_ESCAPE, qtrue, 0, NULL );
	Sys_QueEvent( 0, SE_KEY, A_ESCAPE, qfalse, 0, NULL );
}

}
