MODULE GenericSort; (** AUTHOR "Luc Blaeser"; PURPOSE "Generic Sort Functionality" *)
TYPE
	GenericArray* = POINTER TO ARRAY OF ANY;
	(** has to return true iff obj1 occurs before obj2 *)
	GenericCompareFunct* = PROCEDURE {DELEGATE} (obj1, obj2: ANY): BOOLEAN;

PROCEDURE QuickSort*(VAR genArray: GenericArray; compFunc: GenericCompareFunct);
BEGIN
	(*	An empty array used to be sorted as the range 0 to -1, and the pivot of that range is
		genArray[-1] -- DIV rounds down -- so sorting a result that happened to be empty took the
		process down. Nothing to do below two elements; the recursion never asks for less. *)
	IF LEN(genArray) > 1 THEN QuickSortRec(genArray, compFunc, 0, LEN(genArray)-1) END
END QuickSort;

PROCEDURE QuickSortRec(VAR genArray: GenericArray; comp: GenericCompareFunct; lo, hi: SIZE);
VAR i, j: SIZE; x, t: ANY;
BEGIN
	i := lo; j := hi;
	x := genArray[(lo+hi) DIV 2];

	WHILE (i <= j) DO
		WHILE (comp(genArray[i], x)) DO INC(i) END;
		WHILE (comp(x, genArray[j])) DO DEC(j) END;
		IF (i <= j) THEN
			t := genArray[i]; genArray[i] := genArray[j]; genArray[j] := t;
			INC(i); DEC(j)
		END
	END;

	IF (lo < j) THEN QuickSortRec(genArray, comp, lo, j) END;
	IF (i < hi) THEN QuickSortRec(genArray, comp, i, hi) END
END QuickSortRec;

END GenericSort.
