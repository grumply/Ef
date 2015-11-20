{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Ef.Lang.Scoped.Weave
  ( Weavable, weaver
  , Weaving, weave
  , producer, Producer, Producer'
  , consumer, Consumer, Consumer'
  , pipe, Pipe
  , client, Client, Client'
  , server, Server, Server'
  , woven, Woven(..)
  , Effect, Effect'
  , X
  , cat, for
  , (<\\), (\<\), (~>),  (<~) , (/>/), (//>)
  , (\\<), (/</), (>~),  (~<) , (\>\), (>\\)
  ,        (<~<), (~<<), (>>~), (>~>)
  , (<<+), (<+<), (<-<), (>->), (>+>), (+>>)
  ) where

import Ef.Core

import Control.Applicative
import Control.Monad
import Unsafe.Coerce

data Weaving k
    = FreshScope (Int -> k)
    | forall fs a' a m r. Request Int a' (a  -> Pattern fs m r)
    | forall fs b' b m r. Respond Int b  (b' -> Pattern fs m r)

data Weavable k = Weavable Int k

{-# INLINE freshScope #-}
freshScope :: Is Weaving fs m => Pattern fs m Int
freshScope = self (FreshScope id)

{-# INLINE weaver #-}
weaver :: Uses Weavable fs m => Attribute Weavable fs m
weaver = Weavable 0 $ \fs ->
    let Weavable n k = view fs
        n' = succ n
    in n' `seq` pure (fs .= Weavable n' k)

{-# INLINE getScope #-}
getScope :: Is Weaving fs m => Pattern fs m a -> m Int
getScope p = case p of
    Step sym _ -> case prj sym of
        Just x  -> case x of
            Request i _ _ -> return i
            Respond i _ _ -> return i
            _ -> error "getScope got FreshScope"
        _ -> error "getScope got non-Weaving"
    M m -> m >>= getScope
    _ -> error "getScope error"

instance Symmetry Weavable Weaving where
    symmetry p (Weavable i k) (FreshScope ik) = p k (ik i)

{-# INLINE weave #-}
weave :: Is Weaving fs m => Effect fs m r -> Pattern fs m r
weave e = do
    scope <- freshScope
    go' scope $ runWoven e (\a' apl -> self (Request scope a' apl))
                           (\b b'p -> self (Respond scope b b'p))
  where
    go' scope p0 = go p0
      where
        go p = case p of
            Step sym bp -> case prj sym of
                Just x  -> case x of
                    Request i a' _ ->
                        if i == scope
                        then closed (unsafeCoerce a')
                        else Step sym (go . bp)
                    Respond i b _ ->
                        if i == scope
                        then closed (unsafeCoerce b)
                        else Step sym (go . bp)
                Nothing -> Step sym (go . bp)
            M m -> M (fmap go m)
            Pure r -> Pure r

instance Functor m => Functor (Woven fs a' a b' b m) where
    fmap f (Woven w) = Woven $ \up dn -> fmap f (w up dn)

instance Monad m => Applicative (Woven fs a' a b' b m) where
    pure a = Woven $ \_ _ -> pure a
    wf <*> wx = Woven $ \up dn -> transform up dn (runWoven wf up dn)
      where
        transform up dn = go
          where
            go p = case p of
                Step sym bp -> Step sym (\b -> go (bp b))
                M m -> M (fmap go m)
                Pure f -> fmap f (runWoven wx (unsafeCoerce up)
                                           (unsafeCoerce dn)
                                 )
    (*>) = (>>)

instance Monad m => Monad (Woven fs a' a b' b m) where
  return a = pure a
  r >>= rs = Woven $ \up dn -> do
      v <- runWoven r (unsafeCoerce up) (unsafeCoerce dn)
      runWoven (rs v) up dn

instance (Monad m, Monoid r) => Monoid (Woven fs a' a b' b m r) where
  mempty        = pure mempty
  mappend w1 w2 = Woven $ \up dn -> transform up dn (runWoven w1 up dn)
    where
      transform up dn = go
        where
          go p = case p of
              Step sym bp -> Step sym (\b -> go (bp b))
              M m -> M (fmap go m)
              Pure r -> fmap (mappend r) (runWoven w2 (unsafeCoerce up)
                                                   (unsafeCoerce dn)
                                         )

instance MonadPlus m => Alternative (Woven fs a' a b' b m) where
    empty = mzero
    (<|>) = mplus

instance MonadPlus m => MonadPlus (Woven fs a' a b' b m) where
    mzero = Woven $ \_ _ -> lift_ mzero
    mplus w0 w1 = Woven $ \up dn ->
        transform up dn (runWoven w0 (unsafeCoerce up) (unsafeCoerce dn))
      where
        transform up dn = go
          where
            go p = case p of
                Step sym bp -> Step sym (\b -> go (bp b))
                Pure r -> Pure r
                M m -> M (fmap go m `mplus` return (runWoven w1
                                                             (unsafeCoerce up)
                                                             (unsafeCoerce dn)
                                                   )
                         )

newtype X = X X

{-# INLINE closed #-}
closed :: X -> a
closed (X x) = closed x

type Effect fs m r = Woven fs X () () X m r

type Producer b fs m r = Woven fs X () () b m r
-- producer $ \yield -> do { .. ; }
{-# INLINE producer #-}
producer :: forall fs m b r. Is Weaving fs m
         => ((b -> Pattern fs m ()) -> Pattern fs m r)
         -> Producer' b fs m r
producer f = Woven $ \_ dn -> do
  i <- lift (getScope (dn (unsafeCoerce ()) (unsafeCoerce ())))
  f (\b -> self (Respond i b (return :: forall a. a -> Pattern fs m a)
                )
    )

type Consumer a fs m r = Woven fs () a () X m r
-- consumer $ \await -> do { .. ; }
{-# INLINE consumer #-}
consumer :: forall fs m a r. Is Weaving fs m
         => (Pattern fs m a -> Pattern fs m r)
         -> Consumer' a fs m r
consumer f = Woven $ \up _ -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  f (self (Request i () (return :: forall x. x -> Pattern fs m x)))

type Pipe a b fs m r = Woven fs () a () b m r
-- pipe $ \await yield -> do { .. ; }
{-# INLINE pipe #-}
pipe :: forall fs m a b x r. Is Weaving fs m
     => (Pattern fs m a -> (b -> Pattern fs m x) -> Pattern fs m r)
     -> Pipe a b fs m r
pipe f = Woven $ \up _ -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  f (self (Request i () (return :: forall z. z -> Pattern fs m z)))
    (\b -> self (Respond i b (return :: forall z. z -> Pattern fs m z)))

type Client a' a fs m r = Woven fs a' a () X m r
-- client $ \request -> do { .. ; }
{-# INLINE client #-}
client :: forall fs m a' a r. Is Weaving fs m
       => ((a' -> Pattern fs m a) -> Pattern fs m r)
       -> Client' a' a fs m r
client f = Woven $ \up _ -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  f (\a -> self (Request i a (return :: forall z. z -> Pattern fs m z)))

type Server b' b fs m r = Woven fs X () b' b m r
-- server $ \respond -> do { .. ; }
{-# INLINE server #-}
server :: forall fs m b' b r. Is Weaving fs m
       => ((b -> Pattern fs m b') -> Pattern fs m r)
       -> Server' b' b fs m r
server f = Woven $ \_ dn -> do
  i <- lift (getScope (dn (unsafeCoerce ()) (unsafeCoerce ())))
  f (\b' -> self (Respond i b'
                          (return :: forall z. z -> Pattern fs m z)
                 )
    )

newtype Woven fs a' a b' b m r
  =  Woven
  { runWoven :: (forall x. a' -> (a -> Pattern fs m x) -> Pattern fs m x)
             -> (forall x. b -> (b' -> Pattern fs m x) -> Pattern fs m x)
             -> Pattern fs m r
  }
-- weave $ \request respond -> do { .. ; }
{-# INLINE woven #-}
woven :: forall fs a a' b b' m r. Is Weaving fs m
      => ((a -> Pattern fs m a') -> (b' -> Pattern fs m b) -> Pattern fs m r)
      -> Woven fs a' a b' b m r
woven f = Woven $ \up _ -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  f (\a -> self (Request i a (return :: forall z. z -> Pattern fs m z)))
    (\b' -> self (Respond i b' (return :: forall z. z -> Pattern fs m z)))

type Effect' fs m r = forall x' x y' y . Woven fs x' x y' y m r

type Producer' b fs m r = forall x' x . Woven fs x' x () b m r

type Consumer' a fs m r = forall y' y . Woven fs () a y' y m r

type Server' b' b fs m r = forall x' x . Woven fs x' x b' b m r

type Client' a' a fs m r = forall y' y . Woven fs a' a y' y m r

--------------------------------------------------------------------------------
-- Respond; substitute yields with a function

cat :: Is Weaving fs m => Pipe a a fs m r
cat = pipe $ \awt yld -> forever (awt >>= yld)

{-# INLINE (//>) #-}
infixl 3 //>
(//>) :: forall fs x' x b' b c' c m a'. Is Weaving fs m
      =>       Woven fs x' x b' b m a'
      -> (b -> Woven fs x' x c' c m b')
      ->       Woven fs x' x c' c m a'
p0 //> fb = Woven $ \up dn -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  transform i up dn (runWoven p0 up (unsafeCoerce dn))
  where
    transform scope up dn = go
      where
        go p = case p of
            Step sym bp -> case prj sym of
                Just x  -> case x of
                    Respond i b _ ->
                        if i == scope
                        then do res <- runWoven (fb (unsafeCoerce b))
                                                (unsafeCoerce up)
                                                (unsafeCoerce dn)
                                go (bp (unsafeCoerce res))
                        else Step sym (go . bp)
                    _ -> Step sym (go . bp)
                Nothing -> Step sym (go . bp)
            M m -> M (fmap go m)
            Pure r -> Pure r

{-# INLINE for #-}
for :: Is Weaving fs m
    =>       Woven fs x' x b' b m a'
    -> (b -> Woven fs x' x c' c m b')
    ->       Woven fs x' x c' c m a'
for = (//>)

{-# INLINE (<\\) #-}
infixr 3 <\\
(<\\) :: Is Weaving fs m
      => (b -> Woven fs x' x c' c m b')
      ->       Woven fs x' x b' b m a'
      ->       Woven fs x' x c' c m a'
f <\\ p = p //> f

{-# INLINE (\<\) #-}
infixl 4 \<\
(\<\) :: Is Weaving fs m
      => (b -> Woven fs x' x c' c m b')
      -> (a -> Woven fs x' x b' b m a')
      ->  a -> Woven fs x' x c' c m a'
p1 \<\ p2 = p2 />/ p1

{-# INLINE (~>) #-}
infixr 4 ~>
(~>) :: Is Weaving fs m
     => (a -> Woven fs x' x b' b m a')
     -> (b -> Woven fs x' x c' c m b')
     ->  a -> Woven fs x' x c' c m a'
(~>) = (/>/)

{-# INLINE (<~) #-}
infixl 4 <~
(<~) :: Is Weaving fs m
     => (b -> Woven fs x' x c' c m b')
     -> (a -> Woven fs x' x b' b m a')
     ->  a -> Woven fs x' x c' c m a'
g <~ f = f ~> g

{-# INLINE (/>/) #-}
infixr 4 />/
(/>/) :: Is Weaving fs m
      => (a -> Woven fs x' x b' b m a')
      -> (b -> Woven fs x' x c' c m b')
      ->  a -> Woven fs x' x c' c m a'
(fa />/ fb) a = fa a //> fb

--------------------------------------------------------------------------------
-- Request; substitute awaits with a function

{-# INLINE (>\\) #-}
infixr 4 >\\
(>\\) :: forall fs y' y a' a b' b m c. Is Weaving fs m
      => (b' -> Woven fs a' a y' y m b)
      ->        Woven fs b' b y' y m c
      ->        Woven fs a' a y' y m c
fb' >\\ p0 = Woven $ \up dn -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  transform i up dn (runWoven p0 (unsafeCoerce up) dn)
  where
    transform scope up dn p1 = go p1
      where
        go p = case p of
            Step sym bp -> case prj sym of
                Just x  -> case x of
                    Request i b' _ ->
                        if i == scope
                        then do res <- runWoven (fb' (unsafeCoerce b'))
                                                (unsafeCoerce up)
                                                (unsafeCoerce dn)
                                go (bp (unsafeCoerce res))
                        else Step sym (\b -> go (bp b))
                    _ -> Step sym (\b -> go (bp b))
                Nothing -> Step sym (\b -> go (bp b))
            M m -> M (fmap go m)
            Pure r -> Pure r

{-# INLINE (/</) #-}
infixr 5 /</
(/</) :: Is Weaving fs m
      => (c' -> Woven fs b' b x' x m c)
      -> (b' -> Woven fs a' a x' x m b)
      ->  c' -> Woven fs a' a x' x m c
p1 /</ p2 = p2 \>\ p1

{-# INLINE (>~) #-}
infixr 5 >~
(>~) :: Is Weaving fs m
     => Woven fs a' a y' y m b
     -> Woven fs () b y' y m c
     -> Woven fs a' a y' y m c
p1 >~ p2 = (\() -> p1) >\\ p2

{-# INLINE (~<) #-}
infixl 5 ~<
(~<) :: Is Weaving fs m
     => Woven fs () b y' y m c
     -> Woven fs a' a y' y m b
     -> Woven fs a' a y' y m c
p2 ~< p1 = p1 >~ p2

{-# INLINE (\>\) #-}
infixl 5 \>\
(\>\) :: Is Weaving fs m
      => (b' -> Woven fs a' a y' y m b)
      -> (c' -> Woven fs b' b y' y m c)
      ->  c' -> Woven fs a' a y' y m c
(fb' \>\ fc') c' = fb' >\\ fc' c'

{-# INLINE (\\<) #-}
infixl 4 \\<
(\\<) :: forall fs y' y a' a b' b m c. Is Weaving fs m
      =>        Woven fs b' b y' y m c
      -> (b' -> Woven fs a' a y' y m b)
      ->        Woven fs a' a y' y m c
p \\< f = f >\\ p

--------------------------------------------------------------------------------
-- Push; substitute responds with requests

{-# INLINE (>>~) #-}
infixl 7 >>~
(>>~) :: forall fs a' a b' b c' c m r. Is Weaving fs m
      =>       Woven fs a' a b' b m r
      -> (b -> Woven fs b' b c' c m r)
      ->       Woven fs a' a c' c m r
p0 >>~ fb0 = Woven $ \up dn -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  transform i up dn (runWoven p0 up (unsafeCoerce dn))
  where
    transform scope up dn p1 = go p1
      where
        go = goLeft (\b -> runWoven (fb0 b) (unsafeCoerce up) (unsafeCoerce dn))
          where
            goLeft :: (b -> Pattern fs m r) -> Pattern fs m r -> Pattern fs m r
            goLeft fb = goLeft'
              where
                goLeft' p = case p of
                    Step sym bp -> case prj sym of
                        Just x  -> case x of
                            Respond i b _ ->
                                if i == scope
                                then goRight (unsafeCoerce bp)
                                             (fb (unsafeCoerce b))
                                else Step sym (goLeft' . bp)
                            _ -> Step sym (\b -> goLeft' (bp b))
                        Nothing -> Step sym (\b -> goLeft' (bp b))
                    M m -> M (fmap goLeft' m)
                    Pure r -> Pure r
            goRight :: (b' -> Pattern fs m r) -> Pattern fs m r -> Pattern fs m r
            goRight b'p = goRight'
              where
                goRight' p = case p of
                    Step sym bp -> case prj sym of
                        Just x  -> case x of
                            Request i b' _ ->
                                if i == scope
                                then goLeft (unsafeCoerce bp)
                                            (b'p (unsafeCoerce b'))
                                else Step sym (\b -> goRight' (bp b))
                            _ -> Step sym (\b -> goRight' (bp b))
                        Nothing -> Step sym (\b -> goRight' (bp b))
                    M m -> M (fmap goRight' m)
                    Pure r -> Pure r

{-# INLINE (<~<) #-}
infixl 8 <~<
(<~<) :: Is Weaving fs m
      => (b -> Woven fs b' b c' c m r)
      -> (a -> Woven fs a' a b' b m r)
      ->  a -> Woven fs a' a c' c m r
p1 <~< p2 = p2 >~> p1

{-# INLINE (>~>) #-}
infixr 8 >~>
(>~>) :: Is Weaving fs m
      => (_a -> Woven fs a' a b' b m r)
      -> ( b -> Woven fs b' b c' c m r)
      ->  _a -> Woven fs a' a c' c m r
(fa >~> fb) a = fa a >>~ fb

{-# INLINE (~<<) #-}
infixr 7 ~<<
(~<<) :: Is Weaving fs m
      => (b -> Woven fs b' b c' c m r)
      ->       Woven fs a' a b' b m r
      ->       Woven fs a' a c' c m r
k ~<< p = p >>~ k


--------------------------------------------------------------------------------
-- Pull; substitute requests with responds

{-# INLINE (+>>) #-}
infixr 6 +>>
(+>>) :: forall fs m a' a b' b c' c r. Is Weaving fs m
      => (b' -> Woven fs a' a b' b m r)
      ->        Woven fs b' b c' c m r
      ->        Woven fs a' a c' c m r
fb' +>> p0 = Woven $ \up dn -> do
  i <- lift (getScope (up (unsafeCoerce ()) (unsafeCoerce ())))
  transform i up dn (runWoven p0 (unsafeCoerce up) dn)
  where
    transform scope up dn p1 = go p1
      where
        go = goRight (\b' -> runWoven (fb' b') (unsafeCoerce up)
                                               (unsafeCoerce dn)
                     )
          where
            goRight :: (b' -> Pattern fs m r) -> Pattern fs m r -> Pattern fs m r
            goRight fb'' = goRight'
              where
                goRight' p = case p of
                    Step sym bp -> case prj sym of
                        Just x  -> case x of
                            Request i b' _ ->
                                if i == scope
                                then goLeft (unsafeCoerce bp)
                                            (fb'' (unsafeCoerce b'))
                                else Step sym (\b -> goRight' (bp b))
                            _ -> Step sym (\b -> goRight' (bp b))
                        Nothing -> Step sym (\b -> goRight' (bp b))
                    M m -> M (fmap goRight' m)
                    Pure r -> Pure r
            goLeft :: (b -> Pattern fs m r) -> Pattern fs m r -> Pattern fs m r
            goLeft bp = goLeft'
              where
                goLeft' p = case p of
                    Step sym bp' -> case prj sym of
                        Just x   -> case x of
                            Respond i b _ ->
                                if i == scope
                                then goRight (unsafeCoerce bp')
                                             (bp (unsafeCoerce b))
                                else Step sym (\b' -> goLeft' (bp' b'))
                            _ -> Step sym (\b' -> goLeft' (bp' b'))
                        Nothing -> Step sym (\b' -> goLeft' (bp' b'))
                    M m -> M (fmap goLeft' m)
                    Pure r -> Pure r

{-# INLINE (>->) #-}
infixl 7 >->
(>->) :: Is Weaving fs m
      => Woven fs a' a () b m r
      -> Woven fs () b c' c m r
      -> Woven fs a' a c' c m r
p1 >-> p2 = (\() -> p1) +>> p2

{-# INLINE (<-<) #-}
infixr 7 <-<
(<-<) :: Is Weaving fs m
      => Woven fs () b c' c m r
      -> Woven fs a' a () b m r
      -> Woven fs a' a c' c m r
p2 <-< p1 = p1 >-> p2

{-# INLINE (<+<) #-}
infixr 7 <+<
(<+<) :: Is Weaving fs m
      => (c' -> Woven fs b' b c' c m r)
      -> (b' -> Woven fs a' a b' b m r)
      ->  c' -> Woven fs a' a c' c m r
p1 <+< p2 = p2 >+> p1

{-# INLINE (>+>) #-}
infixl 7 >+>
(>+>) :: Is Weaving fs m
      => ( b' -> Woven fs a' a b' b m r)
      -> (_c' -> Woven fs b' b c' c m r)
      ->  _c' -> Woven fs a' a c' c m r
(fb' >+> fc') c' = fb' +>> fc' c'

{-# INLINE (<<+) #-}
infixl 6 <<+
(<<+) :: forall fs m a' a b' b c' c r. Is Weaving fs m
      =>        Woven fs b' b c' c m r
      -> (b' -> Woven fs a' a b' b m r)
      ->        Woven fs a' a c' c m r
p <<+ fb = fb +>> p

{-# RULES
    "(p //> f) //> g" forall p f g . (p //> f) //> g = p //> (\x -> f x //> g)

  ; "f >\\ (g >\\ p)" forall f g p . f >\\ (g >\\ p) = (\x -> f >\\ g x) >\\ p

  ; "(p >>~ f) >>~ g" forall p f g . (p >>~ f) >>~ g = p >>~ (\x -> f x >>~ g)

  ; "f +>> (g +>> p)" forall f g p . f +>> (g +>> p) = (\x -> f +>> g x) +>> p

  ; "for (for p f) g" forall p f g . for (for p f) g = for p (\a -> for (f a) g)

  ; "f >~ (g >~ p)" forall f g p . f >~ (g >~ p) = (f >~ g) >~ p

  ; "p1 >-> (p2 >-> p3)" forall p1 p2 p3 .
        p1 >-> (p2 >-> p3) = (p1 >-> p2) >-> p3

  #-}