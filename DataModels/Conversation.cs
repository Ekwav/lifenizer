using System;
using System.Collections.Generic;

namespace lifenizer.DataModels
{
    /// <summary>
    /// Represents a or part of a conversation (any kind of information exchange)  
    /// Structure of a ".ls" file 
    /// </summary>
    public class Conversation {
        /// <summary>
        /// An URL or Id to the Original file, can be local, S3 or any other 
        /// </summary>
        /// <value></value>
        public string OriginalUrl { get; set; }
        /// <summary>
        /// A Url the <see cref="IStorage"/> Provider is capable of finding
        /// </summary>
        /// <value></value>
        public string ImportedUrl {get;set;}
        

        /// <summary>
        /// When the information got created, eg letter send date or E-Mail Timestamp
        /// </summary>
        /// <value></value>
        public DateTime CreatedDate { get; set; }

        /// <summary>
        /// Exact Time and Date when Information got consumed (as close as possible)
        /// </summary>
        /// <value></value>
        public DateTime ConsumedDate { get; set; }

        /// <summary>
        /// List of identifiers of participants that participated in the information exchange
        /// </summary>
        public List<string> Participants { get; set; }
        /// <summary>
        /// The sourceType of this data, eg. PDF, chatlog, conversation.
        /// Can contain a `:` seperated path eg: 'PDF:tesseract:eng' 
        /// to improve future recognitions reruns when new version comes out
        /// </summary>
        public string SourceType { get; set; }

        /// <summary>
        /// Topics and similar essential data, helps to improve search
        /// </summary>
        public List<string> Keywords { get; set; }

        /// <summary>
        /// Extra Description of the Data, eg more infromation about Source Like location
        /// </summary>
        public string MetaText { get; set; }

        /// <summary>
        /// Actual Information passed in the conversation
        /// </summary>
        /// <value></value>
        public List<DataPoint> DataPoints { get; set; }

        public Conversation () {
            DataPoints = new List<DataPoint> ();
            Keywords = new List<string> ();
            Participants = new List<string> ();
        }

        public Conversation (string originalUrl, DateTime createdDate, DateTime consumedDate, List<string> participants, string sourceType, List<string> keywords, string metaText, List<DataPoint> dataPoints) {
            OriginalUrl = originalUrl;
            CreatedDate = createdDate;
            ConsumedDate = consumedDate;
            Participants = participants;
            SourceType = sourceType;
            Keywords = keywords;
            MetaText = metaText;
            DataPoints = dataPoints;
        }

        public override bool Equals(object obj)
        {
            return obj is Conversation conversation &&
                   OriginalUrl == conversation.OriginalUrl;
        }

        public override int GetHashCode()
        {
            return HashCode.Combine(OriginalUrl);
        }
    }

}