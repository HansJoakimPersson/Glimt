package Geometry is
   type Point is record
      X : Float;
      Y : Float;
   end record;

   function Distance (Left, Right : Point) return Float;
end Geometry;
