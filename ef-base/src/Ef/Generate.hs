{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
module Ef.Generate
  ( Generator(..)
  , generate
  , each
  , discard
  , every
  ) where



import Ef.Narrative
import Ef.Knot
import Ef.Messages
import Ef.Nat


import Control.Applicative
import Control.Monad
import qualified Data.Foldable as F

import Unsafe.Coerce



newtype Generator self super a =
    Select
        { enumerate
              :: Knows Knot self super
              => Producer a self super ()
        }



instance Functor (Generator self super)
  where

    fmap f (Select p) =
        let
          produce =
              producer . (flip id . f)

        in
          Select (p //> produce)



instance Applicative (Generator self super)
  where

    pure a = Select (producer ($ a))



    mf <*> mx =
        let
          produce f x =
              let
                yields yield =
                    yield (f x)

              in
                producer yields

        in
          Select
              $ for (enumerate mf)
              $ for (enumerate mx)
              . produce



instance Monad (Generator self super)
  where

    return a =
        let
          yields yield =
              yield a

        in
          Select (producer yields)



    m >>= f =
        Select $ for (enumerate m) (enumerate . f)



    fail _ =
        mzero



instance Alternative (Generator self super)
  where

    empty =
        let
          ignore = const (return ())

        in
          Select (producer ignore)



    p1 <|> p2 =
        Select $ knotted $ \up dn ->
            let
              run xs = runKnotted (enumerate xs) (unsafeCoerce up) (unsafeCoerce dn)

            in
              do
                run p1
                run p2



instance MonadPlus (Generator self super)
  where

    mzero =
        empty



    mplus =
        (<|>)



instance Monoid (Generator self super a)
  where

    mempty =
        empty



    mappend =
        (<|>)



generate
    :: Knows Knot self super
    => Generator self super a
    -> Narrative self super ()
generate l =
    let
      complete =
          do
            _ <- l
            mzero

    in
      linearize (enumerate complete)



each
    :: ( Knows Knot self super
       , F.Foldable f
       )
    => f a
    -> Producer' a self super ()
each xs =
    let
      def =
          return ()

      yields yield =
          F.foldr (const . yield) def xs

    in
      producer yields



discard
    :: Monad super
    => t
    -> Knotted self a' a b' b super ()
discard _ =
    let
      ignore _ _ =
          return ()

    in
      Knotted ignore



every
    :: Knows Knot self super
    => Generator self super a
    -> Producer' a self super ()
every it =
    discard >\\ enumerate it



-- | Inlines

{-# INLINE generate #-}
{-# INLINE each #-}
{-# INLINE discard #-}
{-# INLINE every #-}
