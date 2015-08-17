{-# LANGUAGE ViewPatterns, TupleSections, RecordWildCards, ScopedTypeVariables, DeriveDataTypeable, PatternGuards, GADTs #-}

module Output.Tags(Tags, writeTags, readTags, listTags, filterTags, searchTags) where

import Data.List.Extra
import Data.Tuple.Extra
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector.Storable as V
import qualified Data.ByteString.Char8 as BS

import Input.Item
import Query
import General.Util
import General.Store
import General.Str

---------------------------------------------------------------------
-- DATA TYPE

-- matches (a,b) if i >= a && i <= b

data Packages a where Packages :: Packages (Str0, V.Vector (TargetId, TargetId)) deriving Typeable
    -- list of packages, sorted by popularity, lowercase, interspersed with \0
    -- for each index in PackageNames, the first is the module item, any in the bounds are in that package

data Modules a where Modules :: Modules (Str0, V.Vector (TargetId, TargetId)) deriving Typeable
    -- list of modules, sorted by popularity, not unique, lowercase, interspersed with \0
    -- for each index in ModuleNames, the first is the module item, any in the bounds are in that module

data Categories a where Categories :: Categories (Str0, Jagged (TargetId, TargetId)) deriving Typeable
    -- list of categories, sorted by name, interspersed with \0
    -- for each index in CategoryNames, a range of items containing a category, first item is a package

data Completions a where Completions :: Completions Str0 deriving Typeable
    -- a list of things to complete to, interspersed with \0


writeTags :: StoreWrite -> (String -> Bool) -> (String -> [(String,String)]) -> [(Maybe TargetId, Item)] -> IO ()
writeTags store keep extra xs = do
    let splitPkg = splitIPackage xs
    let packages = addRange splitPkg
    storeWrite store Packages (join0 $ map fst packages, V.fromList $ map snd packages)

    let categories = map (first snd . second reverse) $ Map.toList $ Map.fromListWith (++)
            [(((weightTag ex, both lower ex), joinPair ":" ex),[rng]) | (p,rng) <- packages, ex <- extra p]
    storeWrite store Categories (join0 $ map fst categories, jaggedFromList $ map snd categories)

    let modules = addRange $ concatMap (splitIModule . snd) splitPkg
    storeWrite store Modules (join0 $ map (lower . fst) modules, V.fromList $ map snd modules)

    storeWrite store Completions $ join0 $
        takeWhile ("set:" `isPrefixOf`) (map fst categories) ++
        map ("package:"++) (sortOn lower $ filter keep $ map fst packages) ++
        map (joinPair ":") (sortOn (weightTag &&& both lower) $ nubOrd [ex | (p,_) <- packages, keep p, ex <- extra p])
    where
        addRange :: [(String, [(Maybe TargetId,a)])] -> [(String, (TargetId, TargetId))]
        addRange xs = [(a, (minimum is, maximum is)) | (a,b) <- xs, let is = mapMaybe fst b, a /= "", is /= []]

        weightTag ("set",x) = fromMaybe 0.9 $ lookup x [("stackage",0.0),("haskell-platform",0.1)]
        weightTag ("package",x) = 1
        weightTag ("category",x) = 2
        weightTag ("license",x) = 3
        weightTag _ = 4


---------------------------------------------------------------------
-- SIMPLE SELECTORS

listTags :: StoreRead -> [String]
listTags store = map BS.unpack $ split0 $ storeRead store Completions


---------------------------------------------------------------------
-- DATA TYPE, PARSE, PRINT

data Tag = IsExact | IsPackage | IsModule | EqPackage String | EqModule String | EqCategory String String deriving Eq

parseTag :: String -> String -> Maybe Tag
parseTag k v
    | k ~~ "is", v ~~ "exact" = Just IsExact
    | k ~~ "is", v ~~ "package" = Just IsPackage
    | k ~~ "is", v ~~ "module" = Just IsModule
    | k ~~ "package", v /= "" = Just $ EqPackage v
    | k ~~ "module", v /= "" = Just $ EqModule v
    | v /= "" = Just $ EqCategory k v
    | otherwise = Nothing
    where
        -- make the assumption the first letter always disambiguates
        x ~~ lit = x /= "" && lower x `isPrefixOf` lit

showTag :: Tag -> (String, String)
showTag IsExact = ("is","exact")
showTag IsPackage = ("is","package")
showTag IsModule = ("is","module")
showTag (EqPackage x) = ("package",x)
showTag (EqModule x) = ("module",x)
showTag (EqCategory k v) = (k,v)


---------------------------------------------------------------------
-- TAG SEMANTICS

data Tags = Tags
    {packageNames :: Str0
    ,packageIds :: V.Vector (TargetId, TargetId)
    ,categoryNames :: Str0
    ,categoryIds :: Jagged (TargetId, TargetId)
    ,moduleNames :: Str0
    ,moduleIds :: V.Vector (TargetId, TargetId)
    } deriving Typeable

readTags :: StoreRead -> Tags
readTags store = Tags{..}
    where
        (packageNames, packageIds) = storeRead store Packages
        (categoryNames, categoryIds) = storeRead store Categories
        (moduleNames, moduleIds) = storeRead store Modules


lookupTag :: Tags -> Tag -> [(TargetId,TargetId)]
lookupTag Tags{..} IsExact = []
lookupTag Tags{..} IsPackage = map (dupe . fst) $ V.toList packageIds
lookupTag Tags{..} IsModule = map (dupe . fst) $ V.toList moduleIds
lookupTag Tags{..} (EqPackage x) = map (packageIds V.!) $ findIndices (== BS.pack x) $ split0 packageNames
lookupTag Tags{..} (EqModule x) = map (moduleIds V.!) $ findIndices f $ split0 moduleNames
    where
        f | Just x <- stripPrefix "." x, Just x <- stripSuffix "." x = (==) (BS.pack x)
          | Just x <- stripPrefix "." x = BS.isPrefixOf $ BS.pack x
          | otherwise = let y = BS.pack x; y2 = BS.pack $ ('.':x)
                        in \v -> y `BS.isPrefixOf` v || y2 `BS.isInfixOf` v
lookupTag Tags{..} (EqCategory cat val) = concat
    [ V.toList $ jaggedAsk categoryIds i
    | i <- findIndices (== BS.pack (cat ++ ":" ++ val)) $ split0 categoryNames
    ]


filterTags :: Tags -> [Query] -> ([Query], Bool, TargetId -> Bool)
filterTags ts qs = (map redo qs, exact, \i -> all ($ i) fs)
    where fs = map (filterTags2 ts . snd) $ groupSort $ map (scopeCategory &&& id) $ filter isQueryScope qs
          exact = Just IsExact `elem` [parseTag a b | QueryScope True a b <- qs]
          redo (QueryScope sense cat val)
              | Just (k,v) <- showTag <$> parseTag cat val = QueryScope sense k v
              | otherwise = QueryNone $ ['-' | not sense] ++ cat ++ ":" ++ val
          redo q = q


filterTags2 ts qs = \i -> not (negq i) && (null pos || posq i)
    where (posq,negq) = both inRanges (pos,neg)
          (pos, neg) = both (map snd) $ partition fst $ concatMap f qs
          f (QueryScope sense cat val) = map (sense,) $ maybe [] (lookupTag ts) $ parseTag cat val


searchTags :: Tags -> [Query] -> [TargetId]
searchTags ts [] = map fst $ lookupTag ts IsPackage 
searchTags ts qs = if null xs then x else filter (`Set.member` foldl1' Set.intersection (map Set.fromList xs)) x
    where x:xs = [map fst $ maybe [] (lookupTag ts) $ parseTag cat val | QueryScope True cat val <- qs]
