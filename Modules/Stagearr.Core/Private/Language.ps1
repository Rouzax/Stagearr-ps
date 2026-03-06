#Requires -Version 5.1
<#
.SYNOPSIS
    Language code normalization for Stagearr
.DESCRIPTION
    Converts between ISO 639-1 (2-letter), ISO 639-2/T (3-letter), ISO 639-2/B (3-letter),
    and common language names. Provides deterministic normalization without external files.
#>

# Built-in language code lookup table
# Structure: Key = any known code/name (lowercase), Value = { iso1, iso2t, iso2b, name }
$script:SALanguageData = @{
    # Format: code = @{ iso1='xx'; iso2t='xxx'; iso2b='xxx'; name='English Name' }
    
    # Most common languages for subtitles
    'en'      = @{ iso1='en'; iso2t='eng'; iso2b='eng'; name='English' }
    'eng'     = @{ iso1='en'; iso2t='eng'; iso2b='eng'; name='English' }
    'english' = @{ iso1='en'; iso2t='eng'; iso2b='eng'; name='English' }
    
    'nl'      = @{ iso1='nl'; iso2t='nld'; iso2b='dut'; name='Dutch' }
    'nld'     = @{ iso1='nl'; iso2t='nld'; iso2b='dut'; name='Dutch' }
    'dut'     = @{ iso1='nl'; iso2t='nld'; iso2b='dut'; name='Dutch' }
    'dutch'   = @{ iso1='nl'; iso2t='nld'; iso2b='dut'; name='Dutch' }
    
    'de'      = @{ iso1='de'; iso2t='deu'; iso2b='ger'; name='German' }
    'deu'     = @{ iso1='de'; iso2t='deu'; iso2b='ger'; name='German' }
    'ger'     = @{ iso1='de'; iso2t='deu'; iso2b='ger'; name='German' }
    'german'  = @{ iso1='de'; iso2t='deu'; iso2b='ger'; name='German' }
    
    'fr'      = @{ iso1='fr'; iso2t='fra'; iso2b='fre'; name='French' }
    'fra'     = @{ iso1='fr'; iso2t='fra'; iso2b='fre'; name='French' }
    'fre'     = @{ iso1='fr'; iso2t='fra'; iso2b='fre'; name='French' }
    'french'  = @{ iso1='fr'; iso2t='fra'; iso2b='fre'; name='French' }
    
    'es'      = @{ iso1='es'; iso2t='spa'; iso2b='spa'; name='Spanish' }
    'spa'     = @{ iso1='es'; iso2t='spa'; iso2b='spa'; name='Spanish' }
    'spanish' = @{ iso1='es'; iso2t='spa'; iso2b='spa'; name='Spanish' }
    
    'it'      = @{ iso1='it'; iso2t='ita'; iso2b='ita'; name='Italian' }
    'ita'     = @{ iso1='it'; iso2t='ita'; iso2b='ita'; name='Italian' }
    'italian' = @{ iso1='it'; iso2t='ita'; iso2b='ita'; name='Italian' }
    
    'pt'      = @{ iso1='pt'; iso2t='por'; iso2b='por'; name='Portuguese' }
    'por'     = @{ iso1='pt'; iso2t='por'; iso2b='por'; name='Portuguese' }
    'portuguese' = @{ iso1='pt'; iso2t='por'; iso2b='por'; name='Portuguese' }
    
    'ru'      = @{ iso1='ru'; iso2t='rus'; iso2b='rus'; name='Russian' }
    'rus'     = @{ iso1='ru'; iso2t='rus'; iso2b='rus'; name='Russian' }
    'russian' = @{ iso1='ru'; iso2t='rus'; iso2b='rus'; name='Russian' }
    
    'ja'      = @{ iso1='ja'; iso2t='jpn'; iso2b='jpn'; name='Japanese' }
    'jpn'     = @{ iso1='ja'; iso2t='jpn'; iso2b='jpn'; name='Japanese' }
    'japanese' = @{ iso1='ja'; iso2t='jpn'; iso2b='jpn'; name='Japanese' }
    
    'zh'      = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'zho'     = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'chi'     = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'chinese' = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    
    'ko'      = @{ iso1='ko'; iso2t='kor'; iso2b='kor'; name='Korean' }
    'kor'     = @{ iso1='ko'; iso2t='kor'; iso2b='kor'; name='Korean' }
    'korean'  = @{ iso1='ko'; iso2t='kor'; iso2b='kor'; name='Korean' }
    
    'ar'      = @{ iso1='ar'; iso2t='ara'; iso2b='ara'; name='Arabic' }
    'ara'     = @{ iso1='ar'; iso2t='ara'; iso2b='ara'; name='Arabic' }
    'arabic'  = @{ iso1='ar'; iso2t='ara'; iso2b='ara'; name='Arabic' }
    
    'pl'      = @{ iso1='pl'; iso2t='pol'; iso2b='pol'; name='Polish' }
    'pol'     = @{ iso1='pl'; iso2t='pol'; iso2b='pol'; name='Polish' }
    'polish'  = @{ iso1='pl'; iso2t='pol'; iso2b='pol'; name='Polish' }
    
    'tr'      = @{ iso1='tr'; iso2t='tur'; iso2b='tur'; name='Turkish' }
    'tur'     = @{ iso1='tr'; iso2t='tur'; iso2b='tur'; name='Turkish' }
    'turkish' = @{ iso1='tr'; iso2t='tur'; iso2b='tur'; name='Turkish' }
    
    'sv'      = @{ iso1='sv'; iso2t='swe'; iso2b='swe'; name='Swedish' }
    'swe'     = @{ iso1='sv'; iso2t='swe'; iso2b='swe'; name='Swedish' }
    'swedish' = @{ iso1='sv'; iso2t='swe'; iso2b='swe'; name='Swedish' }
    
    'da'      = @{ iso1='da'; iso2t='dan'; iso2b='dan'; name='Danish' }
    'dan'     = @{ iso1='da'; iso2t='dan'; iso2b='dan'; name='Danish' }
    'danish'  = @{ iso1='da'; iso2t='dan'; iso2b='dan'; name='Danish' }
    
    'no'      = @{ iso1='no'; iso2t='nor'; iso2b='nor'; name='Norwegian' }
    'nor'     = @{ iso1='no'; iso2t='nor'; iso2b='nor'; name='Norwegian' }
    'norwegian' = @{ iso1='no'; iso2t='nor'; iso2b='nor'; name='Norwegian' }
    'nb'      = @{ iso1='nb'; iso2t='nob'; iso2b='nob'; name='Norwegian Bokmål' }
    'nob'     = @{ iso1='nb'; iso2t='nob'; iso2b='nob'; name='Norwegian Bokmål' }
    'nn'      = @{ iso1='nn'; iso2t='nno'; iso2b='nno'; name='Norwegian Nynorsk' }
    'nno'     = @{ iso1='nn'; iso2t='nno'; iso2b='nno'; name='Norwegian Nynorsk' }
    
    'fi'      = @{ iso1='fi'; iso2t='fin'; iso2b='fin'; name='Finnish' }
    'fin'     = @{ iso1='fi'; iso2t='fin'; iso2b='fin'; name='Finnish' }
    'finnish' = @{ iso1='fi'; iso2t='fin'; iso2b='fin'; name='Finnish' }
    
    'cs'      = @{ iso1='cs'; iso2t='ces'; iso2b='cze'; name='Czech' }
    'ces'     = @{ iso1='cs'; iso2t='ces'; iso2b='cze'; name='Czech' }
    'cze'     = @{ iso1='cs'; iso2t='ces'; iso2b='cze'; name='Czech' }
    'czech'   = @{ iso1='cs'; iso2t='ces'; iso2b='cze'; name='Czech' }
    
    'sk'      = @{ iso1='sk'; iso2t='slk'; iso2b='slo'; name='Slovak' }
    'slk'     = @{ iso1='sk'; iso2t='slk'; iso2b='slo'; name='Slovak' }
    'slo'     = @{ iso1='sk'; iso2t='slk'; iso2b='slo'; name='Slovak' }
    'slovak'  = @{ iso1='sk'; iso2t='slk'; iso2b='slo'; name='Slovak' }
    
    'hu'      = @{ iso1='hu'; iso2t='hun'; iso2b='hun'; name='Hungarian' }
    'hun'     = @{ iso1='hu'; iso2t='hun'; iso2b='hun'; name='Hungarian' }
    'hungarian' = @{ iso1='hu'; iso2t='hun'; iso2b='hun'; name='Hungarian' }
    
    'ro'      = @{ iso1='ro'; iso2t='ron'; iso2b='rum'; name='Romanian' }
    'ron'     = @{ iso1='ro'; iso2t='ron'; iso2b='rum'; name='Romanian' }
    'rum'     = @{ iso1='ro'; iso2t='ron'; iso2b='rum'; name='Romanian' }
    'romanian' = @{ iso1='ro'; iso2t='ron'; iso2b='rum'; name='Romanian' }
    
    'bg'      = @{ iso1='bg'; iso2t='bul'; iso2b='bul'; name='Bulgarian' }
    'bul'     = @{ iso1='bg'; iso2t='bul'; iso2b='bul'; name='Bulgarian' }
    'bulgarian' = @{ iso1='bg'; iso2t='bul'; iso2b='bul'; name='Bulgarian' }
    
    'el'      = @{ iso1='el'; iso2t='ell'; iso2b='gre'; name='Greek' }
    'ell'     = @{ iso1='el'; iso2t='ell'; iso2b='gre'; name='Greek' }
    'gre'     = @{ iso1='el'; iso2t='ell'; iso2b='gre'; name='Greek' }
    'greek'   = @{ iso1='el'; iso2t='ell'; iso2b='gre'; name='Greek' }
    
    'he'      = @{ iso1='he'; iso2t='heb'; iso2b='heb'; name='Hebrew' }
    'heb'     = @{ iso1='he'; iso2t='heb'; iso2b='heb'; name='Hebrew' }
    'hebrew'  = @{ iso1='he'; iso2t='heb'; iso2b='heb'; name='Hebrew' }
    
    'hi'      = @{ iso1='hi'; iso2t='hin'; iso2b='hin'; name='Hindi' }
    'hin'     = @{ iso1='hi'; iso2t='hin'; iso2b='hin'; name='Hindi' }
    'hindi'   = @{ iso1='hi'; iso2t='hin'; iso2b='hin'; name='Hindi' }
    
    'th'      = @{ iso1='th'; iso2t='tha'; iso2b='tha'; name='Thai' }
    'tha'     = @{ iso1='th'; iso2t='tha'; iso2b='tha'; name='Thai' }
    'thai'    = @{ iso1='th'; iso2t='tha'; iso2b='tha'; name='Thai' }
    
    'vi'      = @{ iso1='vi'; iso2t='vie'; iso2b='vie'; name='Vietnamese' }
    'vie'     = @{ iso1='vi'; iso2t='vie'; iso2b='vie'; name='Vietnamese' }
    'vietnamese' = @{ iso1='vi'; iso2t='vie'; iso2b='vie'; name='Vietnamese' }
    
    'id'      = @{ iso1='id'; iso2t='ind'; iso2b='ind'; name='Indonesian' }
    'ind'     = @{ iso1='id'; iso2t='ind'; iso2b='ind'; name='Indonesian' }
    'indonesian' = @{ iso1='id'; iso2t='ind'; iso2b='ind'; name='Indonesian' }
    
    'ms'      = @{ iso1='ms'; iso2t='msa'; iso2b='may'; name='Malay' }
    'msa'     = @{ iso1='ms'; iso2t='msa'; iso2b='may'; name='Malay' }
    'may'     = @{ iso1='ms'; iso2t='msa'; iso2b='may'; name='Malay' }
    'malay'   = @{ iso1='ms'; iso2t='msa'; iso2b='may'; name='Malay' }
    
    'uk'      = @{ iso1='uk'; iso2t='ukr'; iso2b='ukr'; name='Ukrainian' }
    'ukr'     = @{ iso1='uk'; iso2t='ukr'; iso2b='ukr'; name='Ukrainian' }
    'ukrainian' = @{ iso1='uk'; iso2t='ukr'; iso2b='ukr'; name='Ukrainian' }
    
    'hr'      = @{ iso1='hr'; iso2t='hrv'; iso2b='hrv'; name='Croatian' }
    'hrv'     = @{ iso1='hr'; iso2t='hrv'; iso2b='hrv'; name='Croatian' }
    'croatian' = @{ iso1='hr'; iso2t='hrv'; iso2b='hrv'; name='Croatian' }
    
    'sr'      = @{ iso1='sr'; iso2t='srp'; iso2b='srp'; name='Serbian' }
    'srp'     = @{ iso1='sr'; iso2t='srp'; iso2b='srp'; name='Serbian' }
    'serbian' = @{ iso1='sr'; iso2t='srp'; iso2b='srp'; name='Serbian' }
    
    'sl'      = @{ iso1='sl'; iso2t='slv'; iso2b='slv'; name='Slovenian' }
    'slv'     = @{ iso1='sl'; iso2t='slv'; iso2b='slv'; name='Slovenian' }
    'slovenian' = @{ iso1='sl'; iso2t='slv'; iso2b='slv'; name='Slovenian' }
    
    'et'      = @{ iso1='et'; iso2t='est'; iso2b='est'; name='Estonian' }
    'est'     = @{ iso1='et'; iso2t='est'; iso2b='est'; name='Estonian' }
    'estonian' = @{ iso1='et'; iso2t='est'; iso2b='est'; name='Estonian' }
    
    'lv'      = @{ iso1='lv'; iso2t='lav'; iso2b='lav'; name='Latvian' }
    'lav'     = @{ iso1='lv'; iso2t='lav'; iso2b='lav'; name='Latvian' }
    'latvian' = @{ iso1='lv'; iso2t='lav'; iso2b='lav'; name='Latvian' }
    
    'lt'      = @{ iso1='lt'; iso2t='lit'; iso2b='lit'; name='Lithuanian' }
    'lit'     = @{ iso1='lt'; iso2t='lit'; iso2b='lit'; name='Lithuanian' }
    'lithuanian' = @{ iso1='lt'; iso2t='lit'; iso2b='lit'; name='Lithuanian' }
    
    'fa'      = @{ iso1='fa'; iso2t='fas'; iso2b='per'; name='Persian' }
    'fas'     = @{ iso1='fa'; iso2t='fas'; iso2b='per'; name='Persian' }
    'per'     = @{ iso1='fa'; iso2t='fas'; iso2b='per'; name='Persian' }
    'persian' = @{ iso1='fa'; iso2t='fas'; iso2b='per'; name='Persian' }
    'farsi'   = @{ iso1='fa'; iso2t='fas'; iso2b='per'; name='Persian' }
    
    'is'      = @{ iso1='is'; iso2t='isl'; iso2b='ice'; name='Icelandic' }
    'isl'     = @{ iso1='is'; iso2t='isl'; iso2b='ice'; name='Icelandic' }
    'ice'     = @{ iso1='is'; iso2t='isl'; iso2b='ice'; name='Icelandic' }
    'icelandic' = @{ iso1='is'; iso2t='isl'; iso2b='ice'; name='Icelandic' }
    
    'ga'      = @{ iso1='ga'; iso2t='gle'; iso2b='gle'; name='Irish' }
    'gle'     = @{ iso1='ga'; iso2t='gle'; iso2b='gle'; name='Irish' }
    'irish'   = @{ iso1='ga'; iso2t='gle'; iso2b='gle'; name='Irish' }
    
    'cy'      = @{ iso1='cy'; iso2t='cym'; iso2b='wel'; name='Welsh' }
    'cym'     = @{ iso1='cy'; iso2t='cym'; iso2b='wel'; name='Welsh' }
    'wel'     = @{ iso1='cy'; iso2t='cym'; iso2b='wel'; name='Welsh' }
    'welsh'   = @{ iso1='cy'; iso2t='cym'; iso2b='wel'; name='Welsh' }
    
    'ca'      = @{ iso1='ca'; iso2t='cat'; iso2b='cat'; name='Catalan' }
    'cat'     = @{ iso1='ca'; iso2t='cat'; iso2b='cat'; name='Catalan' }
    'catalan' = @{ iso1='ca'; iso2t='cat'; iso2b='cat'; name='Catalan' }
    
    'eu'      = @{ iso1='eu'; iso2t='eus'; iso2b='baq'; name='Basque' }
    'eus'     = @{ iso1='eu'; iso2t='eus'; iso2b='baq'; name='Basque' }
    'baq'     = @{ iso1='eu'; iso2t='eus'; iso2b='baq'; name='Basque' }
    'basque'  = @{ iso1='eu'; iso2t='eus'; iso2b='baq'; name='Basque' }
    
    'gl'      = @{ iso1='gl'; iso2t='glg'; iso2b='glg'; name='Galician' }
    'glg'     = @{ iso1='gl'; iso2t='glg'; iso2b='glg'; name='Galician' }
    'galician' = @{ iso1='gl'; iso2t='glg'; iso2b='glg'; name='Galician' }
    
    # Undetermined/Unknown/Miscellaneous
    'und'     = @{ iso1=''; iso2t='und'; iso2b='und'; name='Undetermined' }
    'undetermined' = @{ iso1=''; iso2t='und'; iso2b='und'; name='Undetermined' }
    'unk'     = @{ iso1=''; iso2t='und'; iso2b='und'; name='Undetermined' }
    'unknown' = @{ iso1=''; iso2t='und'; iso2b='und'; name='Undetermined' }
    'mis'     = @{ iso1=''; iso2t='mis'; iso2b='mis'; name='Miscellaneous' }
    'mul'     = @{ iso1=''; iso2t='mul'; iso2b='mul'; name='Multiple' }

    # Common dialect/region variants (map to base language)
    'pt-br'   = @{ iso1='pt'; iso2t='por'; iso2b='por'; name='Portuguese' }
    'pt-pt'   = @{ iso1='pt'; iso2t='por'; iso2b='por'; name='Portuguese' }
    'zh-hans' = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'zh-hant' = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'zh-cn'   = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'zh-tw'   = @{ iso1='zh'; iso2t='zho'; iso2b='chi'; name='Chinese' }
    'es-419'  = @{ iso1='es'; iso2t='spa'; iso2b='spa'; name='Spanish' }
    'en-us'   = @{ iso1='en'; iso2t='eng'; iso2b='eng'; name='English' }
    'en-gb'   = @{ iso1='en'; iso2t='eng'; iso2b='eng'; name='English' }
    'fr-ca'   = @{ iso1='fr'; iso2t='fra'; iso2b='fre'; name='French' }
}

function ConvertTo-SALanguageCode {
    <#
    .SYNOPSIS
        Normalizes a language code to a standard format.
    .DESCRIPTION
        Accepts ISO 639-1 (2-letter), ISO 639-2/T (3-letter), ISO 639-2/B (3-letter),
        or common language names and converts to the requested output format.
    .PARAMETER Code
        The input language code or name.
    .PARAMETER To
        Output format: 'iso1' (default), 'iso2t', 'iso2b', or 'name'.
    .EXAMPLE
        ConvertTo-SALanguageCode -Code 'eng'
        # Returns: 'en'
    .EXAMPLE
        ConvertTo-SALanguageCode -Code 'dut' -To 'iso2t'
        # Returns: 'nld'
    .EXAMPLE
        ConvertTo-SALanguageCode -Code 'nl' -To 'name'
        # Returns: 'Dutch'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Code,
        
        [Parameter()]
        [ValidateSet('iso1', 'iso2t', 'iso2b', 'name')]
        [string]$To = 'iso1'
    )
    
    process {
        if ([string]::IsNullOrWhiteSpace($Code)) {
            return $null
        }
        
        $normalized = $Code.ToLower().Trim()
        
        if (-not $script:SALanguageData.ContainsKey($normalized)) {
            # Unknown code - return null
            return $null
        }
        
        $data = $script:SALanguageData[$normalized]
        return $data[$To]
    }
}

function Test-SALanguageCode {
    <#
    .SYNOPSIS
        Tests if a language code is recognized.
    .PARAMETER Code
        The language code to test.
    .EXAMPLE
        Test-SALanguageCode -Code 'eng'
        # Returns: $true
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code
    )
    
    if ([string]::IsNullOrWhiteSpace($Code)) {
        return $false
    }
    
    return $script:SALanguageData.ContainsKey($Code.ToLower().Trim())
}

function Get-SALanguageInfo {
    <#
    .SYNOPSIS
        Gets complete language information for a code.
    .PARAMETER Code
        The language code to look up.
    .EXAMPLE
        Get-SALanguageInfo -Code 'dut'
        # Returns: @{ iso1='nl'; iso2t='nld'; iso2b='dut'; name='Dutch' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code
    )
    
    if ([string]::IsNullOrWhiteSpace($Code)) {
        return $null
    }
    
    $normalized = $Code.ToLower().Trim()
    
    if ($script:SALanguageData.ContainsKey($normalized)) {
        return $script:SALanguageData[$normalized].Clone()
    }
    
    return $null
}
