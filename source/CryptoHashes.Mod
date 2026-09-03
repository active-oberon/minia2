MODULE CryptoHashes;	(** AUTHOR "G.F."; PURPOSE "Empty Hash"; *)

TYPE
	Hash* = OBJECT
		VAR
			name-: ARRAY 64 OF CHAR;
			size-: SIGNED32;
			(*	The compression block, which HMAC pads its key to and which is NOT the same for
				every hash: 64 bytes through SHA-256, 128 from SHA-512 on. It was hard-coded 64
				in CryptoHMAC until 2026-09-03, so a hash with a longer block would have been
				keyed wrongly and silently. Sixty-four is the default because every hash that
				existed before that day has it. *)
			blockSize-: SIGNED32;
			initialized*: BOOLEAN;

		PROCEDURE &Init*;
		BEGIN
			blockSize := 64;
			initialized := FALSE
		END Init;

		PROCEDURE Initialize*;
		BEGIN
			HALT(301) (* force overwriting *)
		END Initialize;

		(** this method is invoked by subclasses *)
		PROCEDURE SetNameAndSize*( CONST name: ARRAY OF CHAR; size: SIGNED32 );
		BEGIN
			COPY( name, SELF.name );
			SELF.size := size;
			(*	Here and not in Init: a subclass that declares its own constructor does not run
				this one's, so a default set there is a default nobody gets -- which read as
				HMAC padding its key to nothing. Every hash calls this. *)
			SELF.blockSize := 64
		END SetNameAndSize;

		(** a hash whose compression block is not 64 bytes says so here, before it is keyed *)
		PROCEDURE SetBlockSize*( bytes: SIGNED32 );
		BEGIN
			SELF.blockSize := bytes
		END SetBlockSize;

		(** data: value to be hashed; when Update is invoked several times before GetHash or Initialize
			is invoked, the concatenation of all data-parameters is hashed *)
		PROCEDURE Update*( CONST data: ARRAY OF CHAR; ofs, len: SIZE );
		BEGIN
			HALT(301) (* force overwriting *)
		END Update;

		(** get the hashvalue of length SELF.size *)
		PROCEDURE GetHash*( VAR buffer: ARRAY OF CHAR; position: SIZE );
		BEGIN
			HALT(301) (* force overwriting *)
		END GetHash;

	END Hash;

	HashFactory = PROCEDURE( ): Hash;

	(** get a new hash from module 'modname' *)
	PROCEDURE NewHash*( CONST modname: ARRAY OF CHAR ): Hash;
	VAR hash : Hash; factory : HashFactory;
	BEGIN
		ASSERT( LEN( modname ) < 57 );
		hash := NIL;
		GETPROCEDURE( modname, "NewHash", factory );
		IF factory # NIL THEN
			hash := factory();
		END;
		RETURN hash;
	END NewHash;

END CryptoHashes.


System.Free CryptoHashes~
