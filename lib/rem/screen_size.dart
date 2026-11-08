import 'package:flutter/material.dart';

class Screen_Size {
  Screen_Size(MediaQueryData data){
    _screenWidth = data.size.width;
    _screenHeight = data.size.height;
  }

  void setSize(BuildContext context){
    _screenWidth = MediaQuery.of(context).size.width;
    _screenHeight = MediaQuery.of(context).size.height;
  }

  Alignment getAlignmentFromOff(Offset offset){
    return Alignment(
      (offset.dx - (_screenWidth / 2)) / (_screenWidth / 2),
      (offset.dy - (_screenHeight / 2)) / (_screenHeight / 2),
    );
  }

  // bool get getIsLarge { return wdiv(1) > hdiv(1) * 0.5; }
  bool get getIsLG { return wdiv(1) > 500.0; }
  bool get getIsXL { return wdiv(1) > 800.0; }

  double get getWidthPosUnit { return wdiv(150); } // For absolute positioning on screens
  double get getHeightPosUnit { return hdiv(150); } // For absolute positioning on screens

  double wdiv(int fraction) { return _screenWidth / fraction.toDouble(); }
  double wfrac(int num, int den) { return _screenWidth * (num.toDouble() / den.toDouble()); }
  double wref(double refWidth){ return refWidth / _screenWidth; }
  double hdiv(int fraction) { return _screenHeight / fraction.toDouble(); }
  double hfrac(int num, int den) { return _screenHeight * (num.toDouble() / den.toDouble()); }
  double href(double refHeight){ return refHeight / _screenHeight; }
  
  late double _screenWidth;
  late double _screenHeight;
}