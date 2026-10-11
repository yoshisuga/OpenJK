// iOS: the engine side of the touch overlay (ios_touch.m). The overlay is
// Objective-C and can't include the engine's headers, so everything it needs
// from the game goes through these plain C functions.

#include "ios_bridge.h"

#include "client/client.h"
#include "sys/sys_local.h"

extern "C" {

int iosJK_IsPlaying( void )
{
	return cls.state == CA_ACTIVE && !( Key_GetCatcher( ) & ( KEYCATCH_UI | KEYCATCH_CONSOLE ) );
}

int iosJK_IsCinematic( void )
{
	return cls.state == CA_CINEMATIC;
}

void iosJK_Command( const char *text )
{
	Cbuf_AddText( text );
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
