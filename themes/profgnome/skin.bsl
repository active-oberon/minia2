skin{
	meta{
		name : "ProfGnome";
		description : "Light Prof-Gnome inspired theme (professional, old-school)";
		author : "minia2";
		date : "2026-07-18";
	}
	window{
		useBitmaps : true;
		title{
			activeLeftMargin : 12;
			activeTopMargin : 17;
			activeColor : 0363636FF;
			activeCloseBitmap : "images/aclose.png";
			activeMinimizeBitmap : "images/amin.png";
			activeMaximizeBitmap : "images/amax.png";
			activeRestoreBitmap : "images/amax.png";
			hoverCloseBitmap : "images/hclose.png";
			hoverMinimizeBitmap : "images/hmin.png";
			hoverMaximizeBitmap : "images/hmax.png";
			inactiveLeftMargin : 12;
			inactiveTopMargin : 17;
			inactiveColor : 0929595FF;
			inactiveCloseBitmap : "images/iclose.png";
			inactiveMinimizeBitmap : "images/imin.png";
			inactiveMaximizeBitmap : "images/imax.png";
			inactiveRestoreBitmap : "images/imax.png";
			spaceBetweenButtons : 6;
		}
		top{
			activeLeft : "images/atl.png";
			activeMiddle : "images/atm.png";
			activeRight : "images/atr.png";
			inactiveLeft : "images/itl.png";
			inactiveMiddle : "images/itm.png";
			inactiveRight : "images/itr.png";
		}
		bottom{
			activeLeft : "images/abl.png";
			activeMiddle : "images/abm.png";
			activeRight : "images/abr.png";
			inactiveLeft : "images/ibl.png";
			inactiveMiddle : "images/ibm.png";
			inactiveRight : "images/ibr.png";
		}
		left{ activeMiddle : "images/alm.png"; inactiveMiddle : "images/ilm.png"; }
		right{ activeMiddle : "images/arm.png"; inactiveMiddle : "images/irm.png"; }
		desktop{
			color : 03584E4FF;
			bgColor : 0E6E6E6FF;
			fgColor : 0252525FF;
			selectColor : 03584E4FF;
		}
	}
	cursor{
		default{ bitmap : "images/arrow.png"; hotX : 0; hotY : 0; }
		move{ bitmap : "images/move.png"; hotX : 10; hotY : 10; }
	}
	component{
		button{
			bounds{ height : 22; width : 64; }
			clDefault : 0E6E6E6FF;
			clHover : 0D8D8D8FF;
			clPressed : 03584E4FF;
			clTextDefault : 0252525FF;
			clTextHover : 0252525FF;
			clTextPressed : 0252525FF;
			fontHeight : 12;
			effect3d : 0;
			useBgBitmaps : FALSE;
		}
		scrollbar{
			width : 14;
			minTrackerSize : 40;
			useTrackerBitmaps : FALSE;
			useArrowBitmaps : FALSE;
			useBackgroundBitmaps : FALSE;
			clDefault : 0DCDCDCFF;
			clHover : 0CDCDCDFF;
			clPressed : 03584E4FF;
			clBtnDefault : 0C0C0C0FF;
			clBtnHover : 03584E4FF;
			clBtnPressed : 03584E4FF;
			effect3d : 0;
		}
	}
}
