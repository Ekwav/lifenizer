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

            var arguments = $" {Program.DefaultDataPath} -type f -name \"*.ls\"  -exec  /usr/bin/agrep -2 -i \"{remainingArguments[0]}\" "+"\"{}\" +";
            Console.WriteLine("full command: \nfind " + arguments);
            ProcessHandler.Instance.RunCommandline("find", arguments)
            .WaitForExit();
            Thread.Sleep(100);

            return 0;
        }
    }
}