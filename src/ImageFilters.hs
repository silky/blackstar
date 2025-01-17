{-# LANGUAGE BangPatterns #-}

module ImageFilters (bloom, supersample) where

import qualified Data.Array.Repa as R
import Data.Array.Repa.Index
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Control.Monad.ST (runST)
import Control.Monad (replicateM_)

import Color

ix1d :: Int -> Int -> Int -> Int
{-# INLINE ix1d #-}
ix1d !w !y !x = y*w + x

boxBlur :: Int -> Int -> RGBImage -> RGBImage
boxBlur !r !passes !img = let
    !sh@(Z :. h :. w) = R.extent img
    rows = U.enumFromN (0 :: Int) h
    cols = U.enumFromN (0 :: Int) w

    -- Functions to safely index a vector representing an image with specialized
    -- horizontal / vertical bound checks. Out of bounds indices return a black
    -- pixel.
    {-# INLINE ixh #-}
    {-# INLINE ixv #-}
    {-# INLINE ix1d' #-}
    ix1d' = ix1d w
    ixh !v !y !x
        | x < 0 || x >= w = (0, 0, 0)
        | otherwise = U.unsafeIndex v $ ix1d' y x
    ixv !v !x !y
        | y < 0 || y >= h = (0, 0, 0)
        | otherwise = U.unsafeIndex v $ ix1d' y x

    -- Normalize by the "width" of the kernel
    normFactor :: Double
    {-# INLINE normFactor #-}
    normFactor = 1 / (2*fromIntegral r + 1)

    {-# INLINE blur #-}
    blur !writeToVec !crds !ix1df !readf !vecIn !y = let
        {-# INLINE pix #-}
        -- A function to yield a pixel from the image vector
        pix = readf vecIn y
        -- Starting value
        startVal = U.foldl1' addRGB . U.map pix . U.unsafeTake r $ crds
        {-# INLINE accumulate #-}
        accumulate !rgb !x = do
            let newRGB =  (rgb `addRGB` pix (x+r)) `subRGB` pix (x-r)
            _ <- writeToVec (ix1df y x) $ mulRGB normFactor newRGB
            return newRGB
        -- Sweep over the row / col of the image
        in U.foldM'_ accumulate startVal crds

    in runST $ do
        mv <- U.thaw $ R.toUnboxed img
        let wrt = MU.unsafeWrite mv
        replicateM_ passes $ do
            -- First blur horizontally
            tmp1 <- U.freeze mv
            U.mapM_ (blur wrt cols ix1d' ixh tmp1) rows
            -- Then vertically
            tmp2 <- U.freeze mv
            U.mapM_ (blur wrt rows (flip ix1d') ixv tmp2) cols
        out <- U.unsafeFreeze mv
        return $ R.fromUnboxed sh out

bloom :: Monad m => Double -> Int -> RGBImage -> m RGBImage
bloom strength divider img = let
    sh@(Z :. _ :. w) = R.extent img
    blurred = boxBlur (w `div` divider) 3 img
    {-# INLINE f #-}
    f !ix = img `R.unsafeIndex` ix `addRGB`
            mulRGB strength (blurred `R.unsafeIndex` ix)
    in R.computeUnboxedP $ R.fromFunction sh f

supersample :: RGBImageDelayed -> RGBImageDelayed
supersample img = let
    Z :. h :. w = R.extent img
    {-# INLINE pix #-}
    pix y x = img `R.unsafeIndex` ix2 y x
    {-# INLINE f #-}
    f (Z :. y :. x) = mulRGB 0.25
        $ pix (2*y) (2*x) `addRGB` pix (2*y+1) (2*x) `addRGB` pix (2*y) (2*x+1)
                          `addRGB` pix (2*y+1) (2*x+1)
    in R.fromFunction (ix2 (h `div` 2) (w `div` 2)) f
