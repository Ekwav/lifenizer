using System;
using System.Linq;
using System.Collections.Generic;
using lifenizer.DataModels;
using Lucene.Net.Analysis.Standard;
using Lucene.Net.Documents;
using Lucene.Net.Index;
using Lucene.Net.Search;
using Lucene.Net.Store;
using Lucene.Net.Util;

namespace lifenizer.Search {
    public class LucenceSearch : ISearcher {
        public string IndexLocation {get;private set;}

        public LucenceSearch(string indexLocation)
        {
            IndexLocation = indexLocation;
        }

        public IEnumerable<string> FindMatches (string searchTerm, int maxDifference) {
            var dir = FSDirectory.Open (IndexLocation);
            var searcher = new IndexSearcher (DirectoryReader.Open (dir)); 
            
            var phrase = new FuzzyQuery (new Term ("data", searchTerm), 2);
            var hits = searcher.Search (phrase, 20 /* top 20 */ ).ScoreDocs;
            foreach (var hit in hits) {
                var foundDoc = searcher.Doc (hit.Doc);
                var score = hit.Score;
                
                var url = foundDoc.Get ("url");
                foundDoc.Get ("favoritePhrase");
                yield return url;
            }
        }

        public void IndexBatch (IEnumerable<Conversation> batch) {
            foreach (var item in batch)
            {
                // this could be optimised
                IndexSingle(item);
            }
        }

        public void IndexSingle (Conversation conversation) {
            var AppLuceneVersion = LuceneVersion.LUCENE_48;
            var dir = FSDirectory.Open (IndexLocation);

            //create an analyzer to process the text
            var analyzer = new StandardAnalyzer (AppLuceneVersion);

            //create an index writer
            var indexConfig = new IndexWriterConfig (AppLuceneVersion, analyzer);
            var writer = new IndexWriter (dir, indexConfig);

            Document d2 = CreateDocumentFromConversation (conversation);

            //writer.AddDocument (d);
            writer.AddDocument (d2);
            writer.Flush (triggerMerge: false, applyAllDeletes: false);
            //phrase.Add (new Term ("text","morgen"));
            //phrase.Add (new Term ("text", "herr")); DirectoryReader.Open(dir));//
            writer.Dispose ();
            

        }
        Document CreateDocumentFromConversation (Conversation conversation) {
            if(conversation == null)
                throw new ArgumentNullException(nameof(conversation));

            var document =  new Document {
                new StringField ("url", conversation.ImportedUrl, Field.Store.YES),
                
            };

            if(conversation.MetaText != null)
                document.Add(new TextField ("metaText", conversation.MetaText, Field.Store.YES));

            foreach (var keyword in conversation.Keywords)
            {
                document.Add(new TextField("keyword",keyword,Field.Store.NO));
            }

            foreach (var dataPoint in conversation.DataPoints)
            {
                document.Add(new TextField("data",dataPoint.Content,Field.Store.NO));
            }

            foreach (var participant in conversation.Participants)
            {
                document.Add(new TextField("participant",participant,Field.Store.YES));
            }


            return document;
        }

    }
}