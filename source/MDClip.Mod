MODULE MDClip; (** AUTHOR "BohdanT"; PURPOSE:  the one place that talks to the system clipboard *)

IMPORT Texts, TextUtilities, Clipboard;

(*
	The A2 clipboard is the text Texts.clipboard. Clipboard (the host interface, here the Windows one) listens
	to its changes and copies the text to the clipboard of the host system, with LF turned into CR LF.
	Clipboard is imported only to be sure that this module is loaded and has registered itself.
*)

(** puts text (UTF-8, lines separated by LF) on the clipboard, replacing what was there *)
PROCEDURE Put*(CONST text: ARRAY OF CHAR);
BEGIN
	Texts.clipboard.AcquireWrite;
	Texts.clipboard.Delete(0, Texts.clipboard.GetLength());
	TextUtilities.StrToText(Texts.clipboard, 0, text);
	Texts.clipboard.ReleaseWrite	(* the listeners, and so the host clipboard, are told here, once *)
END Put;

END MDClip.
