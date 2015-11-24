{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExistentialQuantification #-}
module Ef.Lang.Scoped.Vary
    ( Varying
    , varies
    , Variable
    , varier
    , Vary(..)
    ) where


import Ef.Core

import Unsafe.Coerce



-- | Symbols

data Eagerness
  where

    Strict
        :: Eagerness

    Lazy
        :: Eagerness

  deriving Eq



data Varying k
  where

    FreshScope
        :: (Int -> k)
        -> Varying k

    Modify
        :: Int
        -> Eagerness
        -> (a -> a)
        -> (a -> k)
        -> Varying k



-- | Symbol Module

data Vary fs m st =
    Vary
        {
          modify
              :: (st -> st)
              -> Pattern fs m ()

        , modify'
              :: (st -> st)
              -> Pattern fs m ()

        , get
              :: Pattern fs m st

        , gets
              :: forall a.
                 (st -> a)
              -> Pattern fs m a

        , put
              :: st
              -> Pattern fs m ()

        , puts
              :: forall a.
                 (a -> st)
              -> a
              -> Pattern fs m ()

        , swap
              :: st
              -> Pattern fs m st
        }



-- | Attribute

data Variable k
  where

    Variable
        :: Int
        -> k
        -> Variable k



-- | Attribute Construct

varier
    :: Uses Variable fs m
    => Attribute Variable fs m

varier =
    Variable 0 $ \fs ->
        let
          Variable i k =
              view fs

          i' =
              succ i

        in
          i' `seq` pure $ fs .=
              Variable i' k



-- | Attribute/Symbol Symmetry

instance Witnessing Variable Varying
  where

    witness use (Variable i k) (FreshScope ik) =
        use k (ik i)



-- | Local Scoping Construct + Substitution

varies
    :: forall fs m st r.
       Is Varying fs m
    => st
    -> (    Vary fs m st
         -> Pattern fs m r
       )
    -> Pattern fs m (st,r)

varies startState varying =
    do
      scope <- self (FreshScope id)
      rewrite scope startState $ varying
          Vary
              {
                modify =
                    \setter ->
                        let
                          viewer _ =
                              ()

                        in
                          self (Modify scope Lazy setter viewer)

              , modify' =
                    \setter ->
                        let
                          viewer _ =
                              ()

                        in
                          self (Modify scope Strict setter viewer)

              , get =
                    let
                      setter =
                          id

                      viewer =
                          id

                    in
                      self (Modify scope Lazy setter viewer)

              , gets =
                    \extractor ->
                        let
                          setter =
                              id

                          viewer =
                              extractor

                        in
                          self (Modify scope Lazy setter viewer)

              , put =
                    \newState ->
                        let
                          setter _ =
                              newState

                          viewer _ =
                              ()

                        in
                          self (Modify scope Lazy setter viewer)

              , puts =
                    \extractor hasState ->
                        let
                          newState =
                              extractor hasState

                          setter _ =
                              newState

                          viewer _ =
                              ()

                        in
                          self (Modify scope Lazy setter viewer)

              , swap =
                    \newState ->
                        let
                          setter _ =
                              newState

                          viewer =
                              id

                        in
                          self (Modify scope Lazy setter viewer)
              }
  where

    rewrite rewriteScope =
        withState
      where

        withState st =
            go
          where

            go (Fail e) =
                Fail e

            go (Pure r) =
               Pure (st,r)

            go (M m) =
                M (fmap go m)

            go (Step sym bp) =
                let
                  check currentScope scoped =
                      if currentScope == rewriteScope then
                          scoped
                      else
                          ignore

                  ignore =
                      Step sym (go . bp)

                in
                  case prj sym of

                      Just x ->
                          case x of

                              Modify currentScope strictness setter viewer ->
                                  let
                                    newSt =
                                        unsafeCoerce setter st

                                    continue =
                                        bp (unsafeCoerce viewer st)

                                  in
                                    check currentScope $
                                        if strictness == Strict then
                                            newSt `seq`
                                                withState newSt continue

                                        else
                                            withState newSt continue

                              _ ->
                                  ignore

                      _ ->
                          ignore



-- | Inlines

{-# INLINE varier #-}
{-# INLINE varies #-}
