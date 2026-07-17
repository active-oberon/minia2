(* ETH Oberon, Copyright 2000 ETH Zürich Institut für Computersysteme, ETH Zentrum, CH-8092 Zürich.
Refer to the general ETH Oberon System license contract available at: http://www.oberon.ethz.ch/ *)

MODULE KbdMouse;   (* g.f.	9.7.07 *)

(*	22.1.23  removed calls of X11.RebindKeysym which didn't work in newer Xwindows implementations
	( Fedora >= 37,  macOS (Xquartz > 2.8.2) )
*)

(* replacement for the keyboard and mouse drivers in the Unix ports *)

IMPORT Machine, S := SYSTEM, Inputs, Plugins, X11, Displays, XDisplay, Commands, Objects, Trace;

#IF COOP THEN
	IMPORT Environment;
#END

CONST
	ML = 0;  MM = 1;  MR = 2;

	ModeSwitch = 13;

	MetaMask = { X11.Mod4Mask, ModeSwitch };


VAR
	event: X11.Event;  xbuttons: SET32;
	compstatus: X11.ComposeStatus;

	disp: XDisplay.Display;

	MMseen, MRseen: BOOLEAN;

TYPE
	Poll = OBJECT

		BEGIN {ACTIVE, SAFE,PRIORITY(Objects.High - 1)}
			LOOP
				Objects.Sleep( 15 );  PollXQueue;
				#IF COOP THEN
					IF Environment.status # Environment.Running THEN EXIT END;
				#END
			END
		END Poll;

VAR
	poll: Poll; 
	keySymbol: ARRAY 256 OF SIGNED32;

	PROCEDURE TerminateA2;
	VAR
		res: INTEGER;
		s: ARRAY 256 OF CHAR;
	BEGIN
		Commands.Call( "WMTerminator.Shutdown", {}, res, s );
	END TerminateA2;

	PROCEDURE CheckAlternateKeys( VAR mb: SET );
	BEGIN
		IF ~MMseen & (X11.ControlMask IN xbuttons) THEN INCL( mb, MM ) END;
		IF ~MRseen & (X11.Mod1Mask IN xbuttons) THEN INCL( mb, MR ) END
	END CheckAlternateKeys;


	PROCEDURE SendMouseMsg( x, y, dz: SIGNED32; xbuttons: SET32 );
	VAR mm: Inputs.AbsMouseMsg;
	BEGIN
		Machine.Release( Machine.X11 );
		mm.keys := {};
		mm.x := x;  mm.y := y;  mm.dz := dz;
		IF X11.Button1Mask IN xbuttons THEN  INCL( mm.keys, ML )  END;
		IF X11.Button2Mask IN xbuttons THEN  INCL( mm.keys, MM );  MMseen := TRUE  END;
		IF X11.Button3Mask IN xbuttons THEN  INCL( mm.keys, MR );  MRseen := TRUE  END;
		IF ~(MMseen & MRseen) THEN  CheckAlternateKeys( mm.keys )  END;
		Inputs.mouse.Handle( mm );
		Machine.Acquire( Machine.X11 );
	END SendMouseMsg;

	PROCEDURE SendKeyboardMsg( km: Inputs.KeyboardMsg );
	BEGIN
		Machine.Release( Machine.X11 );
		Inputs.keyboard.Handle( km );
		Machine.Acquire( Machine.X11 );
	END SendKeyboardMsg;
	

	PROCEDURE PollXQueue;
	CONST bufsize = 20;
	VAR keycount, xr, yr, x, y, dz, i: SIGNED32;
		rw, cw: X11.Window;
		keysym: X11.KeySym;  xd: X11.DisplayPtr;
		newxbuttons, bdiff: SET32;
		km: Inputs.KeyboardMsg;
		kp : X11.KeyEvent;
		be : X11.ButtonEvent;
		em: X11.ExposeEvent;
		cm : X11.ClientMessageEvent;
		cn: X11.ConfigureEvent;
		events: SIGNED32;
		buffer: ARRAY bufsize OF CHAR;
	BEGIN
		xd := disp.xdisp;
		Machine.Acquire( Machine.X11 );
		X11.Synchronize(xd, X11.True);
		events := X11.Pending( xd );
		Machine.Release( Machine.X11 );
		WHILE events > 0 DO
			Machine.Acquire( Machine.X11 );
			X11.NextEvent( xd, event );
			CASE event.typ OF
			| X11.KeyPress: kp := S.VAL( X11.KeyEvent, event );
					X11.lastEventTime := kp.time;
					keycount := X11.LookupString( kp, buffer, bufsize, keysym, compstatus );
					X11.QueryPointer( xd, event.window, rw, cw, xr, yr, x, y, newxbuttons );
					IF keycount = 0 THEN
						bdiff := newxbuttons / xbuttons;  xbuttons := newxbuttons;
						km.ch := 0X;
						IF X11.ShiftMask IN bdiff THEN 
							km.keysym := Inputs.KsShiftL
						ELSIF X11.ControlMask IN bdiff THEN
							km.keysym := Inputs.KsControlL; 
							IF ~MMseen THEN  SendMouseMsg( x, y, 0, xbuttons )  END
						ELSIF X11.Mod1Mask IN bdiff THEN
							km.keysym := Inputs.KsAltL;
							IF ~MRseen THEN SendMouseMsg( x, y, 0, xbuttons )  END
						ELSIF MetaMask*bdiff # {} THEN 
							km.keysym := Inputs.KsMetaL
						ELSIF X11.Mod5Mask IN bdiff THEN km.keysym := Inputs.KsAltR
						ELSIF keysym = 0FE20H THEN  (* handle Shift-Tab key *)
							km.keysym := Inputs.KsTab; km.ch :=09X
						ELSIF keysym = 0FF7FH THEN (* NumLock *)
							km.keysym := Inputs.KsNumLock
						ELSE
							km.keysym := MapKeysym( keysym );
						END;
						km.flags := KeyState( );
						SendKeyboardMsg( km )
					ELSE
						IF (X11.ControlMask IN kp.state) & (keysym = 32) THEN (* check Ctrl-space *)
							km.ch := CHR( keysym );  km.flags := KeyState( );
							km.keysym := SIGNED32(keysym);
							SendKeyboardMsg( km ); (* IME keys *)
						ELSE
							xbuttons := newxbuttons;  i := 0;
							WHILE i < keycount DO
								km.ch := buffer[i];
								IF X11.ControlMask IN kp.state THEN
									km.keysym := ORD( km.ch )
								ELSE
									km.keysym := MapKeysym( ORD( km.ch ) )
								END;
								km.flags := KeyState( );
								SendKeyboardMsg( km );
								INC( i )
							END
						END;
					END;
			| X11.KeyRelease: kp := S.VAL(X11.KeyEvent, event);
					X11.lastEventTime := kp.time;
					X11.QueryPointer( xd, event.window, rw, cw, xr, yr, x, y, newxbuttons );
					bdiff := newxbuttons / xbuttons;  xbuttons := newxbuttons;
					IF bdiff # {} THEN
						km.ch := 0X;
						IF X11.ShiftMask IN bdiff THEN km.keysym := Inputs.KsShiftL
						ELSIF X11.ControlMask IN bdiff THEN
							km.keysym := Inputs.KsControlL;	
							IF ~MMseen THEN  SendMouseMsg( x, y, 0, xbuttons )  END 
						ELSIF X11.Mod1Mask IN bdiff THEN
							km.keysym := Inputs.KsAltL;
							IF ~MRseen THEN SendMouseMsg( x, y, 0, xbuttons )  END
						ELSIF MetaMask*bdiff # {} THEN 
							km.keysym := Inputs.KsMetaL
						ELSIF X11.Mod5Mask IN bdiff THEN km.keysym := Inputs.KsAltR
						END;
						km.flags := KeyState( ) + {Inputs.Release};
						SendKeyboardMsg( km )
					END
			| X11.ButtonPress: be := S.VAL(X11.ButtonEvent, event);
					X11.lastEventTime := be.time;
					dz := 0;
					CASE be.button OF
					| X11.Button1:  INCL( xbuttons, X11.Button1Mask )
					| X11.Button2:  INCL( xbuttons, X11.Button2Mask )
					| X11.Button3:  INCL( xbuttons, X11.Button3Mask )
					| X11.Button4: dz := -1
					| X11.Button5: dz := +1
					ELSE  (* ignore *)
					END;
					SendMouseMsg( be.x, be.y, dz, xbuttons )
			| X11.ButtonRelease: be := S.VAL(X11.ButtonEvent, event);
					X11.lastEventTime := be.time;
					CASE be.button OF
					| X11.Button1:  EXCL( xbuttons, X11.Button1Mask )
					| X11.Button2:  EXCL( xbuttons, X11.Button2Mask )
					| X11.Button3:  EXCL( xbuttons, X11.Button3Mask )
					ELSE  (* ignore *)
					END;
					SendMouseMsg( be.x, be.y, 0, xbuttons )
			| X11.MotionNotify:
					X11.QueryPointer( xd, event.window, rw, cw, xr, yr, x, y, xbuttons );
					SendMouseMsg( x, y, 0, xbuttons )
			| X11.Expose, X11.GraphicsExpose:
					em := S.VAL( X11.ExposeEvent, event );
					IF em.count = 0 THEN  (* wait until last message*)
						(* Let DisplayRefresher handle this *)
						km.keysym := 0FFC6H;
						SendKeyboardMsg( km );
					END;
			| X11.NoExpose:
			| X11.MappingNotify:
					X11.RefreshKeyboardMapping( ADDRESSOF( event ) )
			| X11.ClientMessage:
					cm := S.VAL( X11.ClientMessageEvent, event );
					IF  cm.data[0] = disp.wmDelete THEN
						(* shutdown *)
						Machine.Release( Machine.X11 );
						TerminateA2;
						RETURN;
					(*	Modules.Shutdown( Modules.Reboot ); *)
					END;
			| X11.UnmapNotify:
			| X11.MapNotify:
			| X11.SelectionClear:
					IF X11.ClearSelection # NIL THEN X11.ClearSelection(); END
			| X11.SelectionNotify:
					IF X11.ReceiveSelection # NIL THEN
						Machine.Release( Machine.X11 );
						X11.ReceiveSelection( S.VAL( X11.SelectionEvent, event ) );
						Machine.Acquire( Machine.X11 );
					END
			| X11.SelectionRequest:
					IF X11.SendSelection # NIL THEN
						Machine.Release( Machine.X11 );
						X11.SendSelection( S.VAL( X11.SelectionRequestEvent, event ) );
						Machine.Acquire( Machine.X11 )
					END
			| X11.ConfigureNotify:  cn := S.VAL(X11.ConfigureEvent, event);
			ELSE
				(* ignore *)
			END;
			events := X11.Pending( xd );
			Machine.Release( Machine.X11 );
		END;
	END PollXQueue;
	
	
	(* Returns wether key (SHIFT, CTRL or ALT) is pressed *)
	PROCEDURE KeyState( ): SET;
	VAR keys: SET;
	BEGIN
		keys := {};
		IF X11.ShiftMask IN xbuttons THEN  INCL( keys, Inputs.LeftShift )  END;
		IF X11.ControlMask IN xbuttons THEN  INCL( keys, Inputs.LeftCtrl )  END;
		IF X11.Mod1Mask IN xbuttons THEN  INCL( keys, Inputs.LeftAlt )  END;
		IF MetaMask*xbuttons # {} THEN  INCL( keys, Inputs.LeftMeta )  END;
		IF X11.Mod5Mask IN xbuttons THEN  INCL( keys, Inputs.RightAlt )  END;
		RETURN keys
	END KeyState;


	PROCEDURE DisableMouseEmulation*;
	BEGIN
		MMseen := TRUE; MRseen := TRUE;
		Trace.StringLn( "Mouse emulation disabled" )
	END DisableMouseEmulation;

	
	PROCEDURE Init*;
	VAR  val: ARRAY 8 OF CHAR;
	BEGIN		
		Machine.GetConfig( "MB", val );
		IF (val = "3") OR (val = "") THEN
			DisableMouseEmulation
		ELSE
			MMseen := FALSE;  MRseen := FALSE
		END;

		Machine.Acquire( Machine.X11 );
		X11.SelectInput( disp.xdisp, disp.primary,
						  X11.ExposureMask + X11.ButtonPressMask + X11.OwnerGrabButtonMask +
						  X11.ButtonReleaseMask + X11.PointerMotionHintMask + X11.PointerMotionMask +
						  X11.KeyPressMask + X11.KeyReleaseMask + X11.StructureNotifyMask );
		Machine.Release( Machine.X11 );

		InitKeysym;
		
		NEW( poll );
	END Init;
	
	PROCEDURE MapKeysym( ks: X11.KeySym ): SIGNED32;
	VAR sym: SIGNED32;
	BEGIN
		sym := keySymbol[ks MOD 100H];
		IF (ks > 100H) & (sym < 100H) THEN  sym := sym + 0FF00H  END;
		RETURN sym
	END MapKeysym;
	

	PROCEDURE InitKeysym;
	VAR i: SIGNED32;
	BEGIN
		FOR i := 0 TO 255 DO keySymbol[i] := i END;
		keySymbol[008H] := Inputs.KsBackSpace;
		keySymbol[07FH] := Inputs.KsDelete;
		keySymbol[009H] := Inputs.KsTab;
		keySymbol[00AH] := Inputs.KsReturn;
		keySymbol[00DH] := Inputs.KsReturn;

		keySymbol[097H] := Inputs.KsUp;
		keySymbol[099H] := Inputs.KsDown;
		keySymbol[098H] := Inputs.KsRight;
		keySymbol[096H] := Inputs.KsLeft;
		keySymbol[09AH] := Inputs.KsPageUp;
		keySymbol[09BH] := Inputs.KsPageDown;
		keySymbol[095H] := Inputs.KsHome;
		keySymbol[09CH] := Inputs.KsEnd;
		keySymbol[09EH] := Inputs.KsInsert;
		keySymbol[09FH] := Inputs.KsDelete;
	END InitKeysym;


	PROCEDURE GetXDisplay;
	VAR p: Plugins.Plugin;
	BEGIN
		p := Displays.registry.Await( "XDisplay" );  disp := p( XDisplay.Display )
	END GetXDisplay;

BEGIN
	ASSERT( SIGNED32({0} ) = 1 );
	GetXDisplay;
END KbdMouse.



