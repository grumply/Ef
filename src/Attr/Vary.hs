{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
module Attr.Vary
    ( Varying, get, gets, put, puts, swap, modify, modify'
    , Variable, store
    ) where

import Mop.Core

data Varying st k = Modify (st -> st) (st -> k)

data Variable st k = Variable st (st -> k)

instance Symmetry (Variable st) (Varying st) where
    symmetry use (Variable st k) (Modify stst stk) =
        let st' = stst st
        in symmetry use (st,k st') stk

{-# INLINE get #-}
get :: Is (Varying st) fs m => Pattern fs m st
get = self (Modify id id)

{-# INLINE gets #-}
gets :: Is (Varying st) fs m => (st -> a) -> Pattern fs m a
gets f = self (Modify id f)

{-# INLINE put #-}
put :: Is (Varying st) fs m => st -> Pattern fs m ()
put st = self (Modify (const st) (const ()))

{-# INLINE puts #-}
puts :: Is (Varying st) fs m => (a -> st) -> a -> Pattern fs m ()
puts f a = self (Modify (const (f a)) (const ()))

{-# INLINE swap #-}
swap :: Is (Varying st) fs m => st -> Pattern fs m st
swap st = self (Modify (const st) id)

{-# INLINE modify #-}
modify :: Is (Varying st) fs m => (st -> st) -> Pattern fs m ()
modify f = self (Modify f (const ()))

{-# INLINE modify' #-}
modify' :: Is (Varying st) fs m => (st -> st) -> Pattern fs m ()
modify' f = do
    st <- get
    put $! f st

{-# INLINE store #-}
store :: Uses (Variable st) fs m => st -> Attribute (Variable st) fs m
store st0 = Variable st0 (\a fs -> pure $ fs .= store a)
