using System.Collections.Generic;
using lifenizer.DataModels;

namespace lifenizer.Search
{
    public interface ISearcher
    {
        /// <summary>
        /// Get the documentUrls matching a certain search term
        /// </summary>
        /// <param name="searchTerm">The term to search for</param>
        /// <param name="maxDifference">max difference from the search term</param>
        /// <returns>Matching ids</returns>
        IEnumerable<string> FindMatches(string searchTerm,int maxDifference = 0);
        /// <summary>
        /// Indexes multiple .ls files 
        /// </summary>
        /// <param name="batch"></param>
        void IndexBatch(IEnumerable<Conversation> batch);
        /// <summary>
        /// Index single new .ls file
        /// </summary>
        /// <param name="conversation"></param>
        void IndexSingle(Conversation conversation);
    }

    /// <summary>
    /// Identifies a Source
    /// </summary>
    public class Match
    {
        public Match()
        {
        }

        public Match(Conversation conversation,DataPoint context = null)
        {
            Conversation = conversation;
            Context = context;
        }
        /// <summary>
        /// The Matchs meta data
        /// </summary>
        /// <value></value>
        public Conversation Conversation { get; }
        /// <summary>
        /// The exact part that matched
        /// </summary>
        /// <value></value>
        public DataPoint Context {get;}
    }
}