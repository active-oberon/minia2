(**
	Implementation of the PKCS#1 encryption scheme for RSA.
	See RFC 2437.
	Timothée Martiel, 2014
*)
MODULE PKCS1;

	IMPORT CryptoBigNumbers, CryptoRSA, CryptoUtils, KernelLog;

	CONST
		Trace = FALSE;

	(* WriteInteger emits exactly width bytes, including leading zero octets. *)
	PROCEDURE WriteInteger(number: CryptoBigNumbers.BigNumber; VAR dest: ARRAY OF CHAR; ofs, width: SIZE);
	VAR bytes: POINTER TO ARRAY OF CHAR; size, i, index: SIZE;
	BEGIN
		size := 4*number.len; NEW(bytes, size);
		CryptoBigNumbers.GetBinaryValue(number, bytes^, 0);
		FOR i := 0 TO width-1 DO
			index := i+size-width;
			IF index < 0 THEN dest[ofs+i] := 0X ELSE dest[ofs+i] := bytes[index] END
		END
	END WriteInteger;

	(** Encrypts src[srcOfs] .. src[srcOfs + srcLen - 1] with key and writes the result starting from dest[destOfs]. destLen returns the total written length.
		It uses a block type as specified by blockType. blockType can be 0, 1 or 2.
		destLen = 0 iff encryption failed.
	*)
	PROCEDURE Encrypt * (CONST src: ARRAY OF CHAR; srcOfs, srcLen: SIZE; key: CryptoRSA.Key; blockType: SIGNED32; VAR dest: ARRAY OF CHAR; destOfs: SIZE; VAR destLen: SIZE);
		VAR
			k, padd: SIZE;	(* Length of key modulus and padding string. *)
			counter, ofs: SIZE;
			encryptionBlock: POINTER TO ARRAY OF CHAR;
			clear, cipher: CryptoBigNumbers.BigNumber;
			nonzero: BOOLEAN;
	BEGIN
		(* Argument checks *)
		ASSERT(key # NIL);
		destLen := 0;
		IF (blockType < 0) OR (blockType > 2) THEN RETURN END;
		IF key.private # (blockType # 2) THEN RETURN END;
		k := (key.modulus.BitSize()+7) DIV 8;
		IF k < 12 THEN RETURN END;
		IF (srcOfs < 0) OR (srcLen < 0) OR (srcOfs > LEN(src)) THEN RETURN END;
		IF (srcLen > k-11) OR (srcLen > LEN(src)-srcOfs) THEN RETURN END;
		IF (destOfs < 0) OR (destOfs > LEN(dest)) THEN RETURN END;
		IF k > LEN(dest)-destOfs THEN RETURN END;
		IF (blockType = 0) & ((srcLen = 0) OR (src[srcOfs] = 0X)) THEN RETURN END;

		(* Prepare encryption block *)
		NEW(encryptionBlock, k);
		ofs := 0;
		encryptionBlock[ofs] := 0X; INC(ofs);
		encryptionBlock[ofs] := CHR(blockType); INC(ofs);

		(* Fill padding depending on block type. *)
		padd := k - srcLen - 3;
		ASSERT(padd >= 8);
		CASE blockType OF
			 0:
			 	(* 0X *)
			 	FOR counter := ofs TO ofs + padd - 1 DO
			 		encryptionBlock[counter] := 0X
			 	END
			|1:
				(* 0FFH *)
				FOR counter := ofs TO ofs + padd - 1 DO
					encryptionBlock[counter] := 0FFX
				END
			|2:
				(* Random # 0X *)
				REPEAT
					CryptoUtils.RandomBytes(encryptionBlock^, ofs, padd);
					nonzero := TRUE;
					FOR counter := ofs TO ofs + padd - 1 DO
						nonzero := nonzero & (encryptionBlock[counter] # 0X)
					END
				UNTIL nonzero
		END;
		INC(ofs, padd);

		(* Copy separator and data *)
		encryptionBlock[ofs] := 0X; INC(ofs);
		FOR counter := 0 TO srcLen - 1 DO
			encryptionBlock[ofs + counter] := src[srcOfs + counter];
			IF Trace THEN KernelLog.Hex(ORD(src[srcOfs + counter]), -2); KernelLog.String(' ') END
		END;
		IF Trace THEN
			KernelLog.Ln;
			KernelLog.String("PKCS#1:"); KernelLog.Ln;
			KernelLog.Buffer(encryptionBlock^, 0, k)
		END;

		(* Encrypt block *)
		CryptoBigNumbers.AssignBin(clear, encryptionBlock^, 0, k);
		IF key.private THEN cipher := key.Sign(encryptionBlock^, SIGNED32(k)) ELSE cipher := key.Encrypt(clear) END;
		WriteInteger(cipher, dest, destOfs, k);
		destLen := k
	END Encrypt;

	(** Decrypt src[srcOfs] .. src[srcOfs + srcLen - 1] with key, checking for a PKCS#1 formatting with block type blockType.
		The result is written in dest[destOfs] .. dest[destOfs + destLen - 1]. destLen is written with the data length. destLen = 0
		iff decryption failed or PKCS badly formatted.
	*)
	PROCEDURE Decrypt * (CONST src: ARRAY OF CHAR; srcOfs, srcLen: SIZE; key: CryptoRSA.Key; blockType: SIGNED32; VAR dest: ARRAY OF CHAR; destOfs: SIZE; VAR destLen: SIZE);
		VAR
			k, padd: SIZE;
			ofs, counter: SIZE;
			decryptedBlock: POINTER TO ARRAY OF CHAR;
			clear, cipher: CryptoBigNumbers.BigNumber;
	BEGIN
		(* Argument checks. *)
		ASSERT(key # NIL);
		destLen := 0;
		IF (blockType < 0) OR (blockType > 2) THEN RETURN END;
		IF key.private # (blockType = 2) THEN RETURN END;
		k := (key.modulus.BitSize()+7) DIV 8;
		IF (k < 12) OR (srcLen # k) OR (srcOfs < 0) OR (srcOfs > LEN(src)) THEN RETURN END;
		IF srcLen > LEN(src)-srcOfs THEN RETURN END;
		IF (destOfs < 0) OR (destOfs > LEN(dest)) THEN RETURN END;

		(* Decrypt *)
		CryptoBigNumbers.AssignBin(cipher, src, srcOfs, srcLen);
		IF cipher.GEQ(key.modulus) THEN RETURN END;
		IF key.private THEN clear := key.Decrypt(cipher) ELSE clear := key.Encrypt(cipher) END;
		NEW(decryptedBlock, k);
		WriteInteger(clear, decryptedBlock^, 0, k);

		(* Verify PKCS#1 formatting *)
		ofs := 0;
		IF decryptedBlock[ofs] # 0X THEN RETURN END;
		INC(ofs);
		IF decryptedBlock[ofs] # CHR(blockType) THEN RETURN END;
		INC(ofs);
		CASE blockType OF
			 0:
				WHILE (ofs < k) & (decryptedBlock[ofs] = 0X) DO INC(ofs) END;
				padd := ofs-3
			|1:
				WHILE (ofs < k) & (decryptedBlock[ofs] = 0FFX) DO INC(ofs) END;
				padd := ofs-2;
				IF (ofs = k) OR (decryptedBlock[ofs] # 0X) THEN RETURN END;
				INC(ofs)
			|2:
				WHILE (ofs < k) & (decryptedBlock[ofs] # 0X) DO INC(ofs) END;
				padd := ofs-2;
				IF ofs = k THEN RETURN END;
				INC(ofs)
		END;
		IF (padd < 8) OR (ofs >= k) OR (k-ofs > LEN(dest)-destOfs) THEN RETURN END;

		(* ofs points now to the beginning of the data *)
		FOR counter := 0 TO k - ofs - 1 DO
			dest[destOfs + counter] := decryptedBlock[ofs + counter]
		END;
		destLen := k - ofs
	END Decrypt;
END PKCS1.
