module Effect.Writer
    ( Trace, tell
    , Writer, tracer, writer, written
    ) where

import Mop

import Data.Monoid

data Trace r k = Trace r k

data Writer r k = Writer r (r -> k)

instance Pair (Writer r) (Trace r) where
    pair p (Writer _ rk) (Trace r k) = pair p rk (r,k)

tell :: (Has (Trace w) fs m) => w -> Plan fs m ()
tell w = symbol (Trace w ())

writer :: (Monoid w,Uses (Writer w) fs m) => Attribute (Writer w) fs m
writer = tracer mempty (<>)

tracer :: Uses (Writer w) fs m => w -> (w -> w -> w) -> Attribute (Writer w) fs m
tracer w0 f = Writer w0 $ \w' is ->
    let Writer w k = (is&)
    in pure $ is .= Writer (f w w') k

written :: Uses (Writer w) fs m => Object fs m -> w
written fs = let Writer w _ = (fs&) in w
