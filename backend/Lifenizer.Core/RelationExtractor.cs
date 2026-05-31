using System.Text.RegularExpressions;

namespace Lifenizer.Core;

public static partial class RelationExtractor
{
    public static IReadOnlyList<ExtractedRelation> Extract(RelationExtractionRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Text))
        {
            return Array.Empty<ExtractedRelation>();
        }

        var relations = new List<ExtractedRelation>();
        AddPossessiveRelations(request, relations);
        AddDirectRelations(request, relations);

        return relations
            .GroupBy(r => new { r.Subject, r.Relation, r.Object })
            .Select(g => g.OrderByDescending(r => r.Confidence).First())
            .ToArray();
    }

    private static void AddPossessiveRelations(RelationExtractionRequest request, List<ExtractedRelation> relations)
    {
        foreach (Match match in PossessiveRelationRegex().Matches(request.Text))
        {
            var subject = CleanEntity(match.Groups["subject"].Value);
            var owner = CleanEntity(match.Groups["object"].Value);
            var relation = match.Groups["relation"].Value.ToLowerInvariant();
            if (IsUsable(subject) && IsUsable(owner))
            {
                relations.Add(new ExtractedRelation(
                    subject,
                    relation,
                    owner,
                    0.82,
                    match.Value.Trim(),
                    request.EvidenceSegmentId));
            }
        }
    }

    private static void AddDirectRelations(RelationExtractionRequest request, List<ExtractedRelation> relations)
    {
        foreach (Match match in DirectRelationRegex().Matches(request.Text))
        {
            var subject = CleanEntity(match.Groups["subject"].Value);
            var relation = match.Groups["relation"].Value.ToLowerInvariant();
            var obj = CleanEntity(match.Groups["object"].Value);
            if (IsUsable(subject) && IsUsable(obj))
            {
                relations.Add(new ExtractedRelation(
                    subject,
                    relation,
                    obj,
                    0.76,
                    match.Value.Trim(),
                    request.EvidenceSegmentId));
            }
        }
    }

    private static string CleanEntity(string value)
    {
        return Regex.Replace(value.Trim(), "\\s+", " ").Trim(' ', '.', ',', ';', ':', '\'', '"');
    }

    private static bool IsUsable(string value)
    {
        return value.Length >= 2 && value.Any(char.IsLetter);
    }

    [GeneratedRegex(@"(?<subject>[A-Z][\p{L}0-9 _.-]{1,80}?)\s+is\s+(?<object>[A-Z][\p{L}0-9 _.-]{1,80}?)['’]s\s+(?<relation>brother|sister|mother|father|wife|husband|partner|friend|colleague|coworker|cousin|child|son|daughter)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PossessiveRelationRegex();

    [GeneratedRegex(@"(?<subject>[A-Z][\p{L}0-9 _.-]{1,80}?)\s+(?<relation>works with|is married to|married|knows|met|lives with|is friends with)\s+(?<object>[A-Z][\p{L}0-9 _.-]{1,80}?)(?=[.,;:]|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DirectRelationRegex();
}