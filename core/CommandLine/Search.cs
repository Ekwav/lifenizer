using System;
using System.Threading;
using ManyConsole;

namespace lifenizer
{
    public class SearchCommand : ConsoleCommand
    {
        public SearchCommand()
        {
            IsCommand ("search", "Searches imported data");

            HasAdditionalArguments(1, " <searchTerm> ");
        }

        public override int Run(string[] remainingArguments)
        {
            foreach (var item in remainingArguments)
            {
                Console.WriteLine(item);
            }
            var term = remainingArguments[0];
            var searcher = new Search.LucenceSearch("");
            var matches = searcher.FindMatches(term,2);

            foreach (var item in matches)
            {
                Console.WriteLine($"Matched {term} in {item}");
            }
           
            return 0;
        }
    }
}