
module Hoogle.Operations.Rank(rank) where

import General.Code
import Hoogle.TextBase.All
import Hoogle.DataBase.All
import Hoogle.TypeSig.All

-- Privilaged imports
import Hoogle.DataBase.TypeSearch.Cost(Cost(..))


data Cmp = [Cost] :< [Cost]
           deriving Show

data RankTest = RankTest TypeSig [TypeSig]
                deriving Show


rank :: FilePath -> IO ()
rank file = do
    (tb,tests) <- liftM readRankTests $ readFile file
    let rel = concatMap (runRankTest tb) tests
    error $ show rel



readRankTests :: String -> (TextBase,[RankTest])
readRankTests xs = (tb, join $ concatMap parse rest)
    where
        (pre,rest) = break ("@" `isPrefixOf`) $ lines xs
        tb = right $ parseTextBaseString $ unlines pre

        parse :: String -> [(Bool, TypeSig)]
        parse xs | null xs || "--" `isPrefixOf` xs = []
        parse ('@':xs) = [(True,f xs)]
        parse xs = [(False,f xs)]

        f = right . parseTypeSig 
        right (Right x) = x
        right (Left x) = error $ "readRank failed to parse " ++ show x

        join ((_,t):xs) = RankTest t (map snd a) : join b
            where (a,b) = break fst xs
        join [] = []


runRankTest :: TextBase -> RankTest -> [Cmp]
runRankTest tb (RankTest t xs) = []
