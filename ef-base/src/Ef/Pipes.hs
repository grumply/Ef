{-# OPTIONS_GHC -fno-warn-inline-rule-shadowing -fno-warn-missing-methods #-}
module Ef.Pipes
    ( pipe

    , Effect
    , Effect'
    , runEffect

    , Proxy
    , proxy

    , Producer
    , Producer'
    , producer

    , Consumer
    , Consumer'
    , consumer

    , Channel
    , channel

    , Client
    , Client'
    , client

    , Server
    , Server'
    , server

    , X

    , (<\\)
    , (\<\)
    , (~>)
    , (<~)
    , (/>/)
    , (//>)

    , (//<)
    , (/</)
    , (>~)
    , (~<)
    , (\>\)
    , (>\\)

    , (<~<)
    , (~<<)
    , (>>~)
    , (>~>)

    , (<<+)
    , (<+<)
    , (<-<)
    , (>->)
    , (>+>)
    , (+>>)

    , cat
    , for

    , ListT(..)
    , next
    , each
    , every
    , discard
    ) where

import Ef

import Control.Applicative
import qualified Control.Exception as Exc
import Control.Monad
import Data.Foldable as F
import Unsafe.Coerce

data Pipe k
  = Pipe
  | forall a' a super r. Request a' (a -> Narrative '[Pipe] super r)
  | forall b b' super r. Respond b  (b' -> Narrative '[Pipe] super r)

instance Ma Pipe Pipe

newtype X = X X

closed (X x) = closed x

pipe :: Monad super => Trait Pipe '[Pipe] super
pipe = Pipe 

runEffect :: Monad super => Effect super r -> super r
runEffect e = do
  (_,r) <- Object (pipe *:* Empty) $. runProxy e
  return r

type Effect super r = Proxy X () () X super r

type Producer b super r = Proxy X () () b super r

type Consumer a super r = Proxy () a () X super r

type Channel a b super r = Proxy () a () b super r

type Client a' a super r = Proxy a' a () X super r

type Server b' b super r = Proxy X () b' b super r

type Effect' super r = forall x' x y' y. Proxy x' x y' y super r

type Producer' b super r = forall x' x. Proxy x' x () b super r

type Consumer' a super r = forall y' y. Proxy () a y' y super r

type Server' b' b super r = forall x' x. Proxy x' x b' b super r

type Client' a' a super r = forall y' y. Proxy a' a y' y super r

newtype Proxy a' a b' b super r =
    Proxy
        {
          runProxy
              :: Narrative '[Pipe] super r
        }

request a' = self (Request a' Return)
respond b  = self (Respond b  Return)
yield = respond
await = request ()

proxy
    :: forall a a' b b' super r.
       Monad super
    => ((a' -> Narrative '[Pipe] super a) -> (b -> Narrative '[Pipe] super b') -> Narrative '[Pipe] super r)
    -> Proxy a' a b' b super r
proxy f = Proxy $ f request respond

producer
    :: forall super b r.
       Monad super
    => ((b -> Narrative '[Pipe] super ()) -> Narrative '[Pipe] super r)
    -> Producer' b super r
producer f = Proxy $ f respond

consumer
    :: forall super a r.
       Monad super
    => (Narrative '[Pipe] super a -> Narrative '[Pipe] super r)
    -> Consumer' a super r
consumer f =
    Proxy $ f (request ())

channel
    :: forall super a b r.
       Monad super
    => (Narrative '[Pipe] super a -> (b -> Narrative '[Pipe] super ()) -> Narrative '[Pipe] super r)
    -> Channel a b super r
channel f = Proxy $ f (request ()) respond

server
    :: forall super b' b r.
       Monad super
    => ((b -> Narrative '[Pipe] super b') -> Narrative '[Pipe] super r)
    -> Server' b' b super r
server f = Proxy $ f respond

client
    :: forall super a' a r.
       Monad super
    => ((a' -> Narrative '[Pipe] super a) -> Narrative '[Pipe] super r)
    -> Client' a' a super r
client f = Proxy $ f request

--------------------------------------------------------------------------------
-- ListT

newtype ListT super a =
    Select
        { enumerate
              :: Producer a super ()
        }

instance Monad super => Functor (ListT super)
  where

    fmap f (Select p) =
        Select (p //> (producer . flip id . f))

instance Monad super => Applicative (ListT super)
  where

    pure a = Select (producer ($ a))

    mf <*> mx =
        let produce f x = producer ($ f x)
        in Select
              $ for (enumerate mf)
              $ for (enumerate mx)
              . produce

instance Monad super => Monad (ListT super)
  where

    return a =
        let yields yield = yield a
        in Select (producer yields)

    m >>= f = Select $ for (enumerate m) (enumerate . f)

    fail _ = mzero

instance Monad super => Alternative (ListT super)
  where

    empty =
        let ignore = const (return ())
        in Select (producer ignore)

    p1 <|> p2 =
        Select $ proxy $ \up dn ->
            let run xs = runProxy (enumerate xs)
            in do run p1
                  run p2

instance Monad super => MonadPlus (ListT super)
  where

    mzero = empty

    mplus = (<|>)

instance Monad super => Monoid (ListT super a)
  where

    mempty = empty

    mappend = (<|>)


instance (Foldable m) => Foldable (ListT m) where
    foldMap f = go . runProxy . enumerate
      where
        go p =
          case p of
            Return _ -> mempty
            Fail _ -> mempty
            Super sup -> F.foldMap go sup
            Say msg k ->
              case prj msg of
                ~(Just x) ->
                  case x of
                    Request v _  -> closed $ unsafeCoerce v
                    Respond a fu -> f (unsafeCoerce a) `mappend` go (unsafeCoerce fu $ k $ unsafeCoerce ())
    {-# INLINE foldMap #-}

next :: (Monad super, Monad super', super ~ Narrative self' super')
     => Producer a super r -> super (Either r (a,Producer a super r))
next = go . runProxy
  where
    go p = do
      case p of
        Return r -> return (Left r)
        Super sup -> sup >>= go
        Fail e -> throw e
        Say msg k ->
          case prj msg of
            ~(Just x) ->
              case x of
                Request x _ -> closed $ unsafeCoerce x
                Respond a fu -> return (Right (unsafeCoerce a,Proxy $ unsafeCoerce fu $ k $ unsafeCoerce ()))

generate :: Monad super
         => ListT super a -> Narrative '[Pipe] super ()
generate l = runProxy (enumerate (l >> mzero))

each :: (Monad super, F.Foldable f)
     => f a -> Producer' a super ()
each xs =
    let yields yield = F.foldr (const . yield) (return ()) xs
    in producer yields

discard :: Monad super => t -> Proxy a' a b' b super ()
discard _ = proxy $ \_ _ -> return ()

every :: Monad super
      => ListT super a -> Producer' a super ()
every it = discard >\\ enumerate it

--------------------------------------------------------------------------------
-- Respond; substitute yields

cat :: Monad super => Channel a a super r
cat = channel $ \await yield -> forever (await >>= yield)

infixl 3 //>
(//>) :: Monad super
      => Proxy x' x b' b super a'
      -> (b -> Proxy x' x c' c super b')
      -> Proxy x' x c' c super a'
p0 //> fb = Proxy $ substituteResponds fb (runProxy p0)

substituteResponds
    :: forall super x' x c' c b' b a' .
       Monad super
    => (b -> Proxy x' x c' c super b')
    -> Narrative '[Pipe] super a'
    -> Narrative '[Pipe] super a'
substituteResponds fb =
    transform go
  where

    go :: forall z. Messages '[Pipe] z -> (z -> Narrative '[Pipe] super a') -> Narrative '[Pipe] super a'
    go message k =
        case prj message of
            Just (Respond b _) -> do
                res <- runProxy (fb (unsafeCoerce b))
                transform go $ k (unsafeCoerce res)
            _ -> Say message (transform go . k)

for :: Monad super
    => Proxy x' x b' b super a'
    -> (b -> Proxy x' x c' c super b')
    -> Proxy x' x c' c super a'
for = (//>)

infixr 3 <\\
(<\\) :: Monad super
      => (b -> Proxy x' x c' c super b')
      -> Proxy x' x b' b super a'
      -> Proxy x' x c' c super a'
f <\\ p = p //> f

infixl 4 \<\
(\<\) :: Monad super
      => (b -> Proxy x' x c' c super b')
      -> (a -> Proxy x' x b' b super a')
      -> a
      -> Proxy x' x c' c super a'
p1 \<\ p2 = p2 />/ p1

infixr 4 ~>
(~>) :: Monad super
     => (a -> Proxy x' x b' b super a')
     -> (b -> Proxy x' x c' c super b')
     -> a
     -> Proxy x' x c' c super a'
(~>) = (/>/)

infixl 4 <~
(<~) :: Monad super
     => (b -> Proxy x' x c' c super b')
     -> (a -> Proxy x' x b' b super a')
     -> a
     -> Proxy x' x c' c super a'
g <~ f = f ~> g

infixr 4 />/
(/>/) :: Monad super
      => (a -> Proxy x' x b' b super a')
      -> (b -> Proxy x' x c' c super b')
      -> a
      -> Proxy x' x c' c super a'
(fa />/ fb) a = fa a //> fb

--------------------------------------------------------------------------------
-- Request; substitute awaits

infixr 4 >\\
(>\\) :: Monad super
      => (b' -> Proxy a' a y' y super b)
      -> Proxy b' b y' y super c
      -> Proxy a' a y' y super c
fb' >\\ p0 = Proxy $ substituteRequests fb' (runProxy p0)

substituteRequests
    :: forall super x' x c' c b' b a'.
       Monad super
    => (b -> Proxy x' x c' c super b')
    -> Narrative '[Pipe] super a'
    -> Narrative '[Pipe] super a'
substituteRequests fb' =
    transform go
  where

    go :: forall z. Messages '[Pipe] z -> (z -> Narrative '[Pipe] super a') -> Narrative '[Pipe] super a'
    go message k =
        case prj message of
            Just (Request b' _) -> do
                res <- runProxy (fb' (unsafeCoerce b'))
                transform go $ k (unsafeCoerce res)
            _ -> error "Impossible."

infixr 5 /</
(/</) :: Monad super
      => (c' -> Proxy b' b x' x super c)
      -> (b' -> Proxy a' a x' x super b)
      -> c'
      -> Proxy a' a x' x super c
p1 /</ p2 = p2 \>\ p1

infixr 5 >~
(>~) :: Monad super
     => Proxy a' a y' y super b
     -> Proxy () b y' y super c
     -> Proxy a' a y' y super c
p1 >~ p2 = (\() -> p1) >\\ p2

infixl 5 ~<
(~<) :: Monad super
     => Proxy () b y' y super c
     -> Proxy a' a y' y super b
     -> Proxy a' a y' y super c
p2 ~< p1 = p1 >~ p2

infixl 5 \>\
(\>\) :: Monad super
      => (b' -> Proxy a' a y' y super b)
      -> (c' -> Proxy b' b y' y super c)
      -> c'
      -> Proxy a' a y' y super c
(fb' \>\ fc') c' = fb' >\\ fc' c'

infixl 4 //<
(//<) :: Monad super
      => Proxy b' b y' y super c
      -> (b' -> Proxy a' a y' y super b)
      -> Proxy a' a y' y super c
p //< f = f >\\ p

--------------------------------------------------------------------------------
-- Push; substitute responds with requests

infixl 7 >>~
(>>~)
    :: forall a' a b' b c' c super r.
       Monad super
    => Proxy a' a b' b super r
    -> (b -> Proxy b' b c' c super r)
    -> Proxy a' a c' c super r
p0 >>~ fb0 = Proxy $ pushRewrite fb0 p0

pushRewrite
    :: forall super r a' a b' b c' c.
       Monad super
    => (b -> Proxy b' b c' c super r)
    -> Proxy a' a b' b super r
    -> Narrative '[Pipe] super r
pushRewrite fb0 p0 =
    let upstream = runProxy p0
        downstream b = runProxy (fb0 b)
    in go downstream upstream
  where

    go fx =
      transform $ \message k ->
          case prj message of
                Just (Respond b _) ->
                    unsafeCoerce go k (fx (unsafeCoerce b))
                Just (Request b' _) ->
                    unsafeCoerce go k (fx (unsafeCoerce b'))
                _ -> error "Impossible."

infixl 8 <~<
(<~<) :: Monad super
      => (b -> Proxy b' b c' c super r)
      -> (a -> Proxy a' a b' b super r)
      -> a
      -> Proxy a' a c' c super r
p1 <~< p2 = p2 >~> p1

infixr 8 >~>
(>~>) :: Monad super
      => (_a -> Proxy a' a b' b super r)
      -> (b -> Proxy b' b c' c super r)
      -> _a
      -> Proxy a' a c' c super r
(fa >~> fb) a = fa a >>~ fb

infixr 7 ~<<
(~<<) :: Monad super
      => (b -> Proxy b' b c' c super r)
      -> Proxy a' a b' b super r
      -> Proxy a' a c' c super r
k ~<< p = p >>~ k

--------------------------------------------------------------------------------
-- Pull; substitute requests with responds

infixr 6 +>>
(+>>) :: Monad super
      => (b' -> Proxy a' a b' b super r)
      ->        Proxy b' b c' c super r
      ->        Proxy a' a c' c super r
fb' +>> p0 = Proxy $ pullRewrite fb' p0

pullRewrite
    :: forall super a' a b' b c' c r.
       Monad super
    => (b' -> Proxy a' a b' b super r)
    -> Proxy b' b c' c super r
    -> Narrative '[Pipe] super r
pullRewrite fb' p =
    let upstream b' = runProxy (fb' b')
        downstream = runProxy p
    in go upstream downstream
  where

    go fx =
      transform $ \message k ->
          case prj message of
              Just (Respond b _) ->
                  unsafeCoerce go k (fx (unsafeCoerce b))
              Just (Request b' _) ->
                  unsafeCoerce go k (fx (unsafeCoerce b'))
              _ -> error "Impossible."

infixl 7 >->
(>->) :: Monad super
      => Proxy a' a () b super r
      -> Proxy () b c' c super r
      -> Proxy a' a c' c super r
p1 >-> p2 = (\() -> p1) +>> p2

infixr 7 <-<
(<-<) :: Monad super
      => Proxy () b c' c super r
      -> Proxy a' a () b super r
      -> Proxy a' a c' c super r
p2 <-< p1 = p1 >-> p2

infixr 7 <+<
(<+<) :: Monad super
      => (c' -> Proxy b' b c' c super r)
      -> (b' -> Proxy a' a b' b super r)
      -> c'
      -> Proxy a' a c' c super r
p1 <+< p2 = p2 >+> p1

infixl 7 >+>
(>+>) :: Monad super
      => (b' -> Proxy a' a b' b super r)
      -> (_c' -> Proxy b' b c' c super r)
      -> _c'
      -> Proxy a' a c' c super r
(fb' >+> fc') c' = fb' +>> fc' c'

infixl 6 <<+
(<<+) :: Monad super
      => Proxy b' b c' c super r
      -> (b' -> Proxy a' a b' b super r)
      -> Proxy a' a c' c super r
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

  ; "for (for p f) g" forall p f g . for (for p f) g = for p (\a -> for (f a) g)

  ; "f >~ (g >~ p)" forall f g p . f >~ (g >~ p) = (f >~ g) >~ p

  ; "p1 >-> (p2 >-> p3)" forall p1 p2 p3 .
        p1 >-> (p2 >-> p3) = (p1 >-> p2) >-> p3

  ; "p >-> cat" forall p . p >-> cat = p

  ; "cat >-> p" forall p . cat >-> p = p

  #-}


{-# INLINE runEffect #-}
{-# INLINE closed #-}
{-# INLINE producer #-}
{-# INLINE consumer #-}
{-# INLINE channel #-}
{-# INLINE proxy #-}
{-# INLINE server #-}
{-# INLINE client #-}

{-# INLINE substituteResponds #-}
{-# INLINE substituteRequests #-}
{-# INLINE pullRewrite #-}
{-# INLINE pushRewrite #-}

{-# INLINE (//>) #-}
{-# INLINE for #-}
{-# INLINE (<\\) #-}
{-# INLINE (\<\) #-}
{-# INLINE (~>) #-}
{-# INLINE (<~) #-}
{-# INLINE (/>/) #-}

{-# INLINE (>\\) #-}
{-# INLINE (/</) #-}
{-# INLINE (>~) #-}
{-# INLINE (~<) #-}
{-# INLINE (\>\) #-}
{-# INLINE (//<) #-}

{-# INLINE (>>~) #-}
{-# INLINE (<~<) #-}
{-# INLINE (>~>) #-}
{-# INLINE (~<<) #-}

{-# INLINE (+>>) #-}
{-# INLINE (>->) #-}
{-# INLINE (<-<) #-}
{-# INLINE (<+<) #-}
{-# INLINE (>+>) #-}
{-# INLINE (<<+) #-}

{-
{-# INLINE generate #-}
{-# INLINE each #-}
{-# INLINE discard #-}
{-# INLINE every #-}
-}