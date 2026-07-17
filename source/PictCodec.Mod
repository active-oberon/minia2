MODULE PictCodec;
IMPORT
	SYSTEM, Streams, KernelLog, Codecs, Raster, WMGraphics;

CONST
	Ok = 0;

	PictFileId*= -4093;
	R = Raster.r; G = Raster.g; B = Raster.b; A = Raster.a;

TYPE
	PictDecoder* = OBJECT(Codecs.ImageDecoder)
	VAR
		errors, done: BOOLEAN;
		in: Streams.Reader;
		pict: Raster.Image;
		width, height, depth: SIGNED16;
		palette: Raster.Palette;

		PROCEDURE Error(x: ARRAY OF CHAR);
		BEGIN
			KernelLog.String("Oberon Pict Decoder Error: ");
			KernelLog.String(x); KernelLog.Ln;
			done := FALSE;
		END Error;

		PROCEDURE Open*(in: Streams.Reader; VAR res: INTEGER);
		VAR
			id: SIGNED16; i, n: SIGNED32; gen: ARRAY 64 OF CHAR;
			red, green, blue: CHAR;
		BEGIN
			pict := NIL;
			done := FALSE;
			res := -1;

			IF in = NIL THEN Error("Input Stream is NIL"); RETURN END;
			SELF.in := in;

			in.RawInt16(id);
			IF id = 07F7H THEN
				in.RawString(gen);
				in.SkipBytes(4*2);
				in.RawInt16(id);
			END;
			IF id # PictFileId THEN Error("Not an Oberon Pict stream"); RETURN END;

			in.RawInt16(width); in.RawInt16(height); in.RawInt16(depth);

			NEW(palette);
			i := 0; n := ASH(1, depth);
			WHILE i < n DO
				in.Char(red); in.Char(green); in.Char(blue);
				Raster.SetRGB(palette.col[i], ORD(red), ORD(green), ORD(blue));
				INC(i);
			END;

			IF depth = 1 THEN
				Raster.SetRGB(palette.col[0], 255, 255, 255);
				Raster.SetRGB(palette.col[1], 0, 0, 0);
			END;
			Raster.InitPalette(palette, n, 2 + depth DIV 4);

			done := TRUE;
		FINALLY
			IF done THEN
				res := Ok;
			ELSE
				errors := TRUE;
			END;
		END Open;

		PROCEDURE GetImageInfo*(VAR width, height : SIZE; VAR format, maxProgressionLevel : SIGNED32);
		BEGIN
			width := SELF.width;
			height := SELF.height;
		END GetImageInfo;

		PROCEDURE GetNativeImage*(VAR img : Raster.Image);
		VAR
			fmt: Raster.Format; n: SIGNED32; byte: CHAR;
			height := SELF.height;
			a := 0, b: SIZE;
		BEGIN
			IF ~errors THEN
				IF depth = 1 THEN
					Raster.InitFormat(fmt, Raster.custom, 1, 1, {Raster.index}, palette, PackP1, UnpackP1)
				ELSIF depth = 4 THEN
					Raster.InitFormat(fmt, Raster.custom, 4, 1, {Raster.index}, palette, PackP4, UnpackP4)
				ELSE
					Raster.InitPaletteFormat(fmt, palette)
				END;

				NEW(pict);
				Raster.Create(pict, SELF.width, SELF.height, fmt);

				WHILE height > 0 DO
					b := a + pict.bpr;
					WHILE a < b DO
						in.Char(byte);
						n := ORD(byte);
						IF n < 128 THEN
							REPEAT
								in.Char(pict.mem[a]);
								INC(a);	DEC(n)
							UNTIL n < 0;
						ELSE
							n := 257 - n;
							in.Char(byte);
							REPEAT
								pict.mem[a] := byte;
								INC(a); DEC(n)
							UNTIL n < 1;
						END;
					END;
					DEC(height); a := b;
				END;
			END;
			img := pict;
		END GetNativeImage;

		PROCEDURE Render*(img : Raster.Image);
		VAR canvas : WMGraphics.BufferCanvas;
		BEGIN
			GetNativeImage(pict);
			IF ~errors THEN
				NEW(canvas, img);
				canvas.DrawImage(0, 0, pict, WMGraphics.ModeCopy);
			END
		END Render;
	END PictDecoder;

TYPE
	PictEncoder* = OBJECT(Codecs.ImageEncoder)
	VAR out : Streams.Writer;

		PROCEDURE Open*(out : Streams.Writer);
		BEGIN
			SELF.out := out
		END Open;

		PROCEDURE WriteImage*(img: Raster.Image; VAR res: INTEGER);
		VAR
			palette: Raster.Palette; fmt: Raster.Format; mode: Raster.Mode;
			pix: POINTER TO ARRAY OF CHAR;
			buf: ARRAY 129 OF CHAR;
			i, y, a, b, wth: SIZE;
			depth, j: SIGNED16;
			h: CHAR;
			help := FALSE, done := FALSE;
			count: SIGNED8;
		BEGIN
			res := -1;
			Raster.InitMode(mode, Raster.srcCopy);

			out.RawInt16(PictFileId);
			out.RawInt16(img.width(SIGNED16));
			out.RawInt16(img.height(SIGNED16));

			IF (img.fmt.components = {Raster.index}) & (img.fmt.pal # NIL) THEN
				palette := img.fmt.pal;
				IF img.fmt.bpp > 4 THEN
					Raster.InitPaletteFormat(fmt, palette);
					depth := 8
				ELSIF img.fmt.bpp > 1 THEN
					Raster.InitFormat(fmt, Raster.custom, 4, 1, {Raster.index}, palette, PackP4, UnpackP4);
					depth := 4
				ELSE
					Raster.InitFormat(fmt, Raster.custom, 1, 1, {Raster.index}, palette, PackP1, UnpackP1);
					depth := 1
				END
			ELSE
				NEW(palette);
				Raster.ComputePalette(img, palette, 0, 255, 4);
				Raster.InitPaletteFormat(fmt, palette); depth := 8
			END;

			out.RawInt16(depth);
			i := 0;
			WHILE i < ASH(1, depth) DO
				out.Char((palette.col[i, R]));
				out.Char((palette.col[i, G]));
				out.Char((palette.col[i, B]));
				INC(i)
			END;

			NEW(pix, img.bpr);
			y := 0;
			WHILE y < img.height DO
				Raster.GetPixels(img, 0, y, img.width, fmt, pix^, 0, mode);
				wth := img.bpr;
				IF wth # 0 THEN
					a := 0; b := 1;
					j := 1; count := 0;
					buf[1] := pix[0];
					WHILE b < wth DO
						h := pix[b];
						help := (h = buf[j]) & (j = 1);
						IF (b - a < 127) & ((count = 0) OR help OR ((h # buf[j]) & (j > 1))) THEN
							IF h # buf[j] THEN
								INC(count); INC(j);
								buf[j] := h;
							ELSE
								DEC(count)
							END
						ELSE
							IF (buf[j] = h) & ((b - a) # 127) THEN
								DEC(count);
								out.Char(CHR(count + 1));
								out.Char(buf[1])
							ELSE
								out.Char(CHR(count + 1));
								out.Bytes(buf, 1, j)
							END;
							j := 1; count := 0; buf[1] := h; a := b
						END;
						INC(b)
					END;

					IF count >= 0 THEN
						out.Char(CHR(count + 1));
						out.Bytes(buf, 1, j)
					ELSE
						out.Char(CHR(257 + count));
						out.Char(buf[1])
					END
				END;
				INC(y)
			END;
			out.Update;
			done := TRUE;
		FINALLY
			IF done THEN res := Ok END
		END WriteImage;

	END PictEncoder;

(* --- Pack/Unpack --- *)
	PROCEDURE PackP1 (VAR fmt: Raster.Format0; adr: ADDRESS; bit: SIZE; VAR pix: Raster.Pixel);
		VAR b: CHAR;
	BEGIN
		SYSTEM.GET(adr, b);
		IF ORD(pix[R]) + ORD(pix[G]) + ORD(pix[B]) >= 3*128 THEN
			IF ~ODD(ASH(ORD(b), -bit)) THEN
				SYSTEM.PUT(adr, CHR(ORD(b) + ASH(1, bit)))
			END
		ELSE
			IF ODD(ASH(ORD(b), -bit)) THEN
				SYSTEM.PUT(adr, CHR(ORD(b) - ASH(1, bit)))
			END
		END
	END PackP1;

	PROCEDURE UnpackP1 (VAR fmt: Raster.Format0; adr: ADDRESS; bit: SIZE; VAR pix: Raster.Pixel);
		VAR b: CHAR;
	BEGIN
		SYSTEM.GET(adr, b);
		IF ODD(ASH(ORD(b), -bit)) THEN pix[R] := 0X; pix[G] := 0X; pix[B] := 0X; pix[A] := 0FFX
		ELSE pix[R] := 0FFX; pix[G] := 0FFX; pix[B] := 0FFX; pix[A] := 0FFX
		END
	END UnpackP1;

	PROCEDURE PackP4 (VAR fmt: Raster.Format0; adr: ADDRESS; bit: SIZE; VAR pix: Raster.Pixel);
		VAR b: CHAR; i: SIGNED32;
	BEGIN
		SYSTEM.GET(adr, b);
		i := Raster.PaletteIndex(fmt.pal, ORD(pix[R]), ORD(pix[G]), ORD(pix[B])) MOD 10H;
		IF bit = 0 THEN SYSTEM.PUT(adr, CHR(ORD(b) - ORD(b) MOD 10H + i))
		ELSE SYSTEM.PUT(adr, CHR(ORD(b) MOD 10H + 10H*i))
		END
	END PackP4;

	PROCEDURE UnpackP4 (VAR fmt: Raster.Format0; adr: ADDRESS; bit: SIZE; VAR pix: Raster.Pixel);
		VAR b: CHAR;
	BEGIN
		SYSTEM.GET(adr, b); pix := fmt.pal.col[ASH(ORD(b), -bit) MOD 10H]
	END UnpackP4;

	PROCEDURE EncoderFactory*(): Codecs.ImageEncoder;
	BEGIN
		RETURN NEW PictEncoder();
	END EncoderFactory;

	PROCEDURE DecoderFactory*(): Codecs.ImageDecoder;
	BEGIN
		RETURN NEW PictDecoder();
	END DecoderFactory;

END PictCodec.